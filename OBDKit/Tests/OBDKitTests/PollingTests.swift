import XCTest
@testable import OBDKit

final class SchedulerTests: XCTestCase {
    /// Simulates the adapter with the measured costs: 112 ms per request, 150 ms per module change.
    func run(_ plan: PollPlan, seconds: Double) -> (counts: [String: Int], switches: Int, requests: Int, maxPack: Int) {
        var s = Scheduler(items: plan.items, now: 0)
        var t = 0.0, header: UInt16? = nil
        var counts: [String: Int] = [:], switches = 0, requests = 0, maxPack = 0
        while t < seconds {
            guard let r = s.next(now: t, currentHeader: header) else { t += 0.1; continue }
            if r.header != header { switches += 1; t += 0.15; header = r.header }
            s.didSend(r, at: t)
            t += 0.112
            requests += 1
            maxPack = max(maxPack, r.keys.count)
            for k in r.keys { counts[k, default: 0] += 1 }
        }
        return (counts, switches, requests, maxPack)
    }

    func carPlan() -> PollPlan {
        let supported = StandardPIDs.supported(base: 0x00, bitmap: [0xBE, 0x3F, 0xA8, 0x13])
            .union(StandardPIDs.supported(base: 0x20, bitmap: [0x90, 0x1F, 0xF0, 0x11]))
            .union(StandardPIDs.supported(base: 0x40, bitmap: [0xFE, 0xDC, 0x80, 0x41]))
            .union(StandardPIDs.supported(base: 0x60, bitmap: [0x08, 0x00, 0x00, 0x00]))
        return PollPlan.build(supported: supported, profile: BuiltInProfiles.profile(id: "subaru-outback-2010-25i-cvt"))
    }

    func testPlanForTheCar() {
        let plan = carPlan()
        XCTAssertEqual(plan.items.filter { if case .mode01 = $0.request { return true } else { return false } }.count, 44)
        XCTAssertEqual(plan.items.filter { if case .profile = $0.request { return true } else { return false } }.count, 10)
        XCTAssertEqual(plan.inactive.count, 2) // the two that never carry information
        XCTAssertEqual(plan.itemKeyForSignal["oil_temp"], "7E0:A800000113")
        XCTAssertEqual(plan.itemKeyForSignal["rpm"], "7E0:01:0C")
    }

    func testPacksSixAndKeepsEverythingMoving() {
        let plan = carPlan()
        let r = run(plan, seconds: 120)
        XCTAssertEqual(r.maxPack, 6)
        // Every active item gets polled; nothing starves.
        for item in plan.items { XCTAssertGreaterThan(r.counts[item.key, default: 0], 0, item.key) }
        // Fast signals stay fast: engine speed close to twice a second on average, even with
        // everything on, the transmission reads and conservative (two-command) module changes.
        XCTAssertGreaterThan(Double(r.counts["7E0:01:0C"]!) / 120, 1.8)
        // Coolant at least every 2 s.
        XCTAssertGreaterThan(Double(r.counts["7E0:01:05"]!) / 120, 0.5)
        // Transmission reads every few seconds.
        XCTAssertGreaterThan(Double(r.counts["7E1:A800000056"]!) / 120, 0.2)
        // Module changes are batched: far fewer than one per transmission read.
        let transmissionReads = plan.items.filter { $0.header == 0x7E1 }.reduce(0) { $0 + r.counts[$1.key, default: 0] }
        XCTAssertLessThan(Double(r.switches), Double(transmissionReads) * 0.6, "switches \(r.switches) vs reads \(transmissionReads)")
        let fast = Double(r.counts["7E0:01:0C"]!) / 120
        print("scheduler: \(r.requests) requests, \(r.switches) module changes, rpm \(fast)/s, transmission reads \(transmissionReads)")
        for item in plan.items.sorted(by: { $0.key < $1.key }) {
            print("  \(item.key) target \(item.period)s achieved \(String(format: "%.2f", 120 / Double(r.counts[item.key, default: 1])))s")
        }
    }

    func testRelativeRatesFollowPeriods() {
        let a = PollItem(header: 0x7E0, request: .profile(id: "a", command: "A800000001"), period: 0.5)
        let b = PollItem(header: 0x7E0, request: .profile(id: "b", command: "A800000002"), period: 2)
        let plan = PollPlan(items: [a, b], inactive: [], signals: [:], itemKeyForSignal: [:], profileSensors: [:])
        let r = run(plan, seconds: 60)
        let ratio = Double(r.counts[a.key]!) / Double(r.counts[b.key]!)
        XCTAssertEqual(ratio, 4, accuracy: 0.6)
    }

    func testBlockedItemsAreSkipped() {
        let a = PollItem(header: 0x7E0, request: .profile(id: "a", command: "A800000001"), period: 1)
        var s = Scheduler(items: [a], now: 0)
        s.block(a.key, until: 10)
        XCTAssertNil(s.next(now: 5, currentHeader: nil))
        XCTAssertNotNil(s.next(now: 10, currentHeader: nil))
    }
}

final class CapabilityTests: XCTestCase {
    func testStates() {
        var m = CapabilityMap(fingerprint: "x")
        let now = Date()
        XCTAssertEqual(m.recordMiss("a", status: .negative, nrc: 0x13, at: now), .infinity)
        XCTAssertEqual(m.state("a"), .unsupported)

        XCTAssertNil(m.recordMiss("b", status: .silent, nrc: nil, at: now))
        XCTAssertEqual(m.recordMiss("b", status: .silent, nrc: nil, at: now), 600)
        XCTAssertEqual(m.state("b"), .silent)

        m.recordAnswer("c", at: now)
        XCTAssertNil(m.recordMiss("c", status: .silent, nrc: nil, at: now))
        XCTAssertNil(m.recordMiss("c", status: .silent, nrc: nil, at: now))
        XCTAssertEqual(m.recordMiss("c", status: .silent, nrc: nil, at: now), 15)
        XCTAssertEqual(m.state("c"), .active)
        m.recordAnswer("c", at: now)
        XCTAssertEqual(m.records["c"]?.consecutiveMisses, 0)

        let data = try! JSONEncoder().encode(m)
        XCTAssertEqual(try! JSONDecoder().decode(CapabilityMap.self, from: data), m)
    }
}

final class PollerTests: XCTestCase {
    func testEndToEndAgainstSimulatedCar() async throws {
        let sim = SimulatedAdapter(latency: 0.002, startAt: 600)
        let session = ELMSession(transport: sim)
        let info = try await AdapterSetup.initialize(session)
        XCTAssertEqual(info.supportedPIDs(responder: 0x7E8).count, 47)

        var profile = try XCTUnwrap(BuiltInProfiles.profile(id: "subaru-outback-2010-25i-cvt"))
        // An address this car rejects: must end up unsupported and stop being asked.
        profile.sensors.append(ProfileSensor(id: "bogus", name: "Bogus", module: "7E1", ssm: "00004A", did: nil, bytes: nil, signed: nil,
                                             scale: nil, offset: nil, unit: .raw, category: nil, period: 0.5, status: "raw",
                                             enabled: nil, range: nil, evidence: nil))
        let plan = PollPlan.build(supported: info.supportedPIDs(responder: 0x7E8), profile: profile)
        let poller = Poller(session: session, plan: plan, capability: CapabilityMap(fingerprint: info.fingerprint))
        let runTask = Task { await poller.run() }

        let collector = Task { () -> ([SignalID: Double], PollerStats?) in
            var latest: [SignalID: Double] = [:]
            var stats: PollerStats?
            for await e in poller.events {
                switch e {
                case .samples(let s): for x in s { latest[x.signal] = x.value }
                case .stats(let s): stats = s
                default: break
                }
            }
            return (latest, stats)
        }
        try await Task.sleep(nanoseconds: 2_500_000_000)

        // Exclusive work between polls (trouble codes) goes through.
        let codes = try await poller.perform { s in try await TroubleCodes.readAll(s) }
        XCTAssertEqual(codes, [])

        await poller.stop()
        await runTask.value
        let (latest, stats) = await collector.value
        let capability = await poller.currentCapability()

        for id in ["rpm", "speed", "coolant_temp", "maf", "fuel_level", "oil_temp", "cvt_fluid_temp", "turbine_speed", "adapter_voltage"] {
            XCTAssertNotNil(latest[SignalID(id)], id)
        }
        XCTAssertNil(latest["atf_deterioration"], "disabled by default")
        XCTAssertEqual(capability.state("7E1:A80000004A"), .unsupported)
        XCTAssertEqual(capability.state("7E1:A800000056"), .active)
        XCTAssertNotNil(stats)
        XCTAssertGreaterThan(stats?.requestsPerSecond ?? 0, 1)
        for cmd in sim.received { XCTAssertNoThrow(try ReadOnlyGuard.check(cmd), cmd) }
        // The rejected address was asked once, then left alone.
        XCTAssertEqual(sim.received.filter { $0 == "A80000004A" }.count, 1)
    }

    func testDetectsIgnitionOffAndOn() async throws {
        let sim = SimulatedAdapter(latency: 0.002)
        let session = ELMSession(transport: sim)
        let info = try await AdapterSetup.initialize(session, readIdentity: false)
        let plan = PollPlan.build(supported: info.supportedPIDs(responder: 0x7E8), profile: nil)
        let poller = Poller(session: session, plan: plan, capability: CapabilityMap(fingerprint: info.fingerprint))
        let runTask = Task { await poller.run() }
        let states = Task { () -> [VehicleState] in
            var seen: [VehicleState] = []
            for await e in poller.events { if case .vehicle(let v) = e { seen.append(v) } }
            return seen
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        sim.setIgnition(on: false, engineRunning: false)
        try await Task.sleep(nanoseconds: 800_000_000)
        sim.setIgnition(on: true, engineRunning: true)
        try await Task.sleep(nanoseconds: 2_600_000_000)
        await poller.stop()
        await runTask.value
        let seen = await states.value
        XCTAssertEqual(seen, [.offline, .online])
        // Being off didn't get working sensors written off.
        let capability = await poller.currentCapability()
        XCTAssertEqual(capability.state("7E0:01:0C"), .active)
    }

    func testDisconnectEndsTheLoop() async throws {
        let sim = SimulatedAdapter(latency: 0.002)
        let session = ELMSession(transport: sim)
        let info = try await AdapterSetup.initialize(session, readIdentity: false)
        let poller = Poller(session: session, plan: PollPlan.build(supported: info.supportedPIDs(responder: 0x7E8), profile: nil),
                            capability: CapabilityMap(fingerprint: ""))
        let runTask = Task { await poller.run() }
        let reason = Task { () -> String? in
            for await e in poller.events { if case .finished(let r) = e { return r } }
            return nil
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        sim.setConnected(false)
        await runTask.value
        let r = await reason.value
        XCTAssertEqual(r, "disconnected")
    }
}
