import Foundation

public enum VehicleState: String, Sendable {
    /// Modules answer (ignition on).
    case online
    /// Nothing answers: ignition off, or the bus went quiet.
    case offline
}

public struct PollerStats: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var state: CapabilityMap.State
        /// Measured time between answers (smoothed), seconds.
        public var achievedPeriod: Double?
        public var lastAnswer: Date?
        public var blocked: Bool
    }

    public var requestsPerSecond: Double = 0
    public var valuesPerSecond: Double = 0
    public var commandsSent = 0
    public var items: [String: Item] = [:]

    public init() {}
}

public enum PollerEvent: Sendable {
    case samples([Sample])
    case vehicle(VehicleState)
    case stats(PollerStats)
    case capability(CapabilityMap)
    case note(String)
    case finished(reason: String)
}

/// Runs the polling loop: picks the next request from the scheduler, sends it, decodes the
/// reply into samples, and keeps the capability map current. One poller per connection.
public actor Poller {
    public nonisolated let events: AsyncStream<PollerEvent>
    private let continuation: AsyncStream<PollerEvent>.Continuation

    private let session: ELMSession
    private var plan: PollPlan
    private var scheduler: Scheduler
    private var capability: CapabilityMap
    private var capabilityDirty = false

    private struct Job {
        let run: @Sendable (ELMSession) async -> Void
        let cancel: @Sendable () -> Void
    }
    private var jobs: [Job] = []
    private var stopRequested = false
    private var finished = false

    private var offline = false
    private var consecutiveCoreMisses = 0
    private var lastCoreAnswer = -Double.infinity
    private var lastVoltageRead = -Double.infinity
    /// Seconds between adapter supply-voltage reads (0 = never).
    public var voltageInterval: Double = 15

    private let t0 = ContinuousClock.now
    private func now() -> Double { t0.duration(to: .now).seconds }

    private var requestTimes: [Double] = []
    private var valueTimes: [(Double, Int)] = []
    private var answerTiming: [String: (last: Double, period: Double?)] = [:]
    private var lastAnswerDate: [String: Date] = [:]

    public init(session: ELMSession, plan: PollPlan, capability: CapabilityMap) {
        self.session = session
        self.plan = plan
        self.capability = capability
        self.scheduler = Scheduler(items: plan.items, now: 0)
        var c: AsyncStream<PollerEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(500)) { c = $0 }
        self.continuation = c
    }

    // MARK: control

    public func stop() { stopRequested = true }

    public func currentPlan() -> PollPlan { plan }

    public func currentCapability() -> CapabilityMap { capability }

    /// Runs `body` with exclusive use of the adapter between two poll requests
    /// (e.g. reading trouble codes).
    public func perform<T: Sendable>(_ body: @escaping @Sendable (ELMSession) async throws -> T) async throws -> T {
        if finished { throw OBDError.disconnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            jobs.append(Job(
                run: { session in
                    do { cont.resume(returning: try await body(session)) } catch { cont.resume(throwing: error) }
                },
                cancel: { cont.resume(throwing: OBDError.disconnected) }
            ))
        }
    }

    public func setPeriod(_ key: String, _ period: Double) {
        scheduler.setPeriod(key, period)
        if let i = plan.items.firstIndex(where: { $0.key == key }) { plan.items[i].period = period }
    }

    public func setEnabled(_ key: String, _ on: Bool) {
        if on, let i = plan.inactive.firstIndex(where: { $0.key == key }) {
            let item = plan.inactive.remove(at: i)
            plan.items.append(item)
            scheduler.add(item, now: now())
        } else if !on, let i = plan.items.firstIndex(where: { $0.key == key }) {
            plan.inactive.append(plan.items.remove(at: i))
            scheduler.remove(key)
        }
    }

    /// Forget what we learned about an item and ask again.
    public func reprobe(_ key: String) {
        capability.reset(key)
        capabilityDirty = true
        scheduler.block(key, until: now())
    }

    // MARK: loop

    public func run() async {
        let start = now()
        for key in scheduler.keys {
            switch capability.state(key) {
            case .unsupported: scheduler.block(key, until: .infinity)
            case .silent: scheduler.block(key, until: start + 20) // one retry per connection, once things settle
            default: break
            }
        }
        var lastStats = start
        var lastCapability = start
        var reason = "stopped"
        loop: while !stopRequested && !Task.isCancelled {
            if !jobs.isEmpty {
                let pending = jobs
                jobs = []
                for job in pending { await job.run(session) }
                continue
            }
            let t = now()
            if t - lastStats >= 1 {
                emitStats()
                lastStats = t
            }
            if capabilityDirty && t - lastCapability >= 10 {
                continuation.yield(.capability(capability))
                capabilityDirty = false
                lastCapability = t
            }
            do {
                if offline {
                    try await probeVehicle()
                    continue
                }
                if voltageInterval > 0 && t - lastVoltageRead >= voltageInterval {
                    lastVoltageRead = t
                    if let v = try await AdapterSetup.readVoltage(session) {
                        emit([Sample(AdapterSignals.batteryVoltage, v, Date())])
                    }
                    continue
                }
                guard let req = scheduler.next(now: t, currentHeader: session.currentHeader) else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                do {
                    try await session.setTarget(req.header)
                } catch let e as OBDError where e != .disconnected {
                    continuation.yield(.note("couldn't address \(hex3(req.header)): \(e)"))
                    for key in req.keys { scheduler.block(key, until: t + 30) }
                    continue
                }
                let sent = now()
                let reply = try await session.send(req.command, timeout: 2.5)
                scheduler.didSend(req, at: sent)
                requestTimes.append(now())
                handle(reply, req)
            } catch OBDError.disconnected {
                reason = "disconnected"
                break loop
            } catch is CancellationError {
                break loop
            } catch {
                continuation.yield(.note("\(error)"))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        finished = true
        for job in jobs { job.cancel() }
        jobs = []
        continuation.yield(.capability(capability))
        continuation.yield(.finished(reason: reason))
        continuation.finish()
    }

    private func probeVehicle() async throws {
        try await session.setTarget(PollPlan.engineHeader)
        let r = try await session.send("010C", timeout: 3)
        let c = ReplyClassifier.classify(r, request: "010C", expectFrom: PollPlan.engineHeader + 8)
        if c.status == .answers {
            offline = false
            consecutiveCoreMisses = 0
            lastCoreAnswer = now()
            // Items that were answering before the car went quiet go straight back into rotation.
            for key in scheduler.keys where capability.state(key) == .active { scheduler.block(key, until: now()) }
            continuation.yield(.vehicle(.online))
            if let pid = StandardPIDs.all[0x0C], let data = StandardPIDs.split(c.payload)[0x0C] {
                emit(pid.decode(data).map { Sample($0.0, $0.1, Date()) })
            }
        } else {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func handle(_ reply: ELMReply, _ req: PlannedRequest) {
        let time = Date()
        let expected = req.header + 8
        if req.command.hasPrefix("01") {
            let payload = ISOTP.messages(from: reply.lines)[expected]?.first { $0.first == 0x41 }
            if let payload {
                coreAnswered()
                let data = StandardPIDs.split(payload)
                var samples: [Sample] = []
                for key in req.keys {
                    guard let item = scheduler.item(key), case .mode01(let pid) = item.request else { continue }
                    if let d = data[pid], let def = StandardPIDs.all[pid] {
                        samples += def.decode(d).map { Sample($0.0, $0.1, time) }
                        answered(key, time)
                    } else {
                        miss(key, .silent, nil, time)
                    }
                }
                emit(samples)
            } else {
                let c = ReplyClassifier.classify(reply, request: String(req.command.prefix(4)), expectFrom: expected)
                let wasOnline = now() - lastCoreAnswer < 3
                coreMissed()
                if wasOnline || c.status == .notSupported || c.status == .negative {
                    for key in req.keys { miss(key, c.status, c.nrc, time) }
                }
            }
            return
        }
        guard let key = req.keys.first, let item = scheduler.item(key),
              case .profile(let id, _) = item.request, let sensor = plan.profileSensors[id] else { return }
        let c = ReplyClassifier.classify(reply, request: req.command, expectFrom: expected)
        if c.status == .answers, let v = sensor.decode(sensor.valueBytes(fromPositive: c.payload)) {
            answered(key, time)
            emit([Sample(sensor.signalID, v, time)])
        } else if now() - lastCoreAnswer < 3 || c.status == .notSupported || c.status == .negative {
            // Only hold silence against a sensor while the engine computer is answering;
            // otherwise the whole car is quiet and it says nothing about this sensor.
            miss(key, c.status, c.nrc, time)
        }
    }

    private func coreAnswered() {
        consecutiveCoreMisses = 0
        lastCoreAnswer = now()
    }

    private func coreMissed() {
        consecutiveCoreMisses += 1
        if consecutiveCoreMisses >= 3 && !offline {
            offline = true
            continuation.yield(.vehicle(.offline))
        }
    }

    private func answered(_ key: String, _ time: Date) {
        if capability.state(key) != .active { capabilityDirty = true }
        capability.recordAnswer(key, at: time)
        let t = now()
        if let prev = answerTiming[key] {
            let dt = t - prev.last
            let smoothed = prev.period.map { $0 * 0.8 + dt * 0.2 } ?? dt
            answerTiming[key] = (t, smoothed)
        } else {
            answerTiming[key] = (t, nil)
        }
        lastAnswerDate[key] = time
    }

    private func miss(_ key: String, _ status: ReplyStatus, _ nrc: UInt8?, _ time: Date) {
        let before = capability.state(key)
        if let backoff = capability.recordMiss(key, status: status, nrc: nrc, at: time) {
            scheduler.block(key, until: now() + backoff)
        }
        if capability.state(key) != before { capabilityDirty = true }
    }

    private func emit(_ samples: [Sample]) {
        guard !samples.isEmpty else { return }
        valueTimes.append((now(), samples.count))
        continuation.yield(.samples(samples))
    }

    private func emitStats() {
        let t = now()
        let window = 5.0
        requestTimes.removeAll { t - $0 > window }
        valueTimes.removeAll { t - $0.0 > window }
        var stats = PollerStats()
        let span = min(window, max(1, t))
        stats.requestsPerSecond = Double(requestTimes.count) / span
        stats.valuesPerSecond = Double(valueTimes.reduce(0) { $0 + $1.1 }) / span
        stats.commandsSent = session.commandsSent
        for item in plan.items + plan.inactive {
            stats.items[item.key] = PollerStats.Item(
                state: capability.state(item.key),
                achievedPeriod: answerTiming[item.key]?.period,
                lastAnswer: lastAnswerDate[item.key],
                blocked: scheduler.isBlocked(item.key, now: t) || !plan.items.contains(item)
            )
        }
        continuation.yield(.stats(stats))
    }
}
