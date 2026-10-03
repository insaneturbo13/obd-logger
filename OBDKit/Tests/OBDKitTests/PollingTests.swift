import XCTest
@testable import OBDKit

final class SchedulerTests: XCTestCase {
    /// Simulates the adapter with the measured costs: 112 ms per request, 150 ms per module change.
    /// `requestCost` models a slower link. The raw export of a 2026-10-02 drive matched 112 ms:
    /// engine speed every 0.41 s, coolant 0.92 s, module voltage 1.67 s (simulated 0.44/0.94/1.74).
    func run(_ plan: PollPlan, seconds: Double, requestCost: Double = 0.112) -> (counts: [String: Int], switches: Int, requests: Int, maxPack: Int) {
        Self.simulate(plan, seconds: seconds, requestCost: requestCost)
    }

    static func simulate(_ plan: PollPlan, seconds: Double, requestCost: Double = 0.112) -> (counts: [String: Int], switches: Int, requests: Int, maxPack: Int) {
        var s = Scheduler(items: plan.items, now: 0)
        var t = 0.0, header: UInt16? = nil
        var counts: [String: Int] = [:], switches = 0, requests = 0, maxPack = 0
        while t < seconds {
            guard let r = s.next(now: t, currentHeader: header) else { t += 0.1; continue }
            if r.header != header { switches += 1; t += 0.15 * requestCost / 0.112; header = r.header }
            s.didSend(r, at: t)
            t += requestCost
            requests += 1
            maxPack = max(maxPack, r.keys.count)
            for k in r.keys { counts[k, default: 0] += 1 }
        }
        return (counts, switches, requests, maxPack)
    }

    func carPlan() -> PollPlan { Self.outbackPlan() }

    static func outbackPlan() -> PollPlan {
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
        // Transmission reads every few seconds (turbine speed; the fluid temperature is slow on purpose).
        XCTAssertGreaterThan(Double(r.counts["7E1:A80000004F"]!) / 120, 0.2)
        // Module changes are batched: far fewer than one per transmission read.
        let transmissionReads = plan.items.filter { $0.header == 0x7E1 }.reduce(0) { $0 + r.counts[$1.key, default: 0] }
        XCTAssertLessThan(Double(r.switches), Double(transmissionReads) * 0.6, "switches \(r.switches) vs reads \(transmissionReads)")
        let fast = Double(r.counts["7E0:01:0C"]!) / 120
        print("scheduler: \(r.requests) requests, \(r.switches) module changes, rpm \(fast)/s, transmission reads \(transmissionReads)")
        for item in plan.items.sorted(by: { $0.key < $1.key }) {
            print("  \(item.key) target \(item.period)s achieved \(String(format: "%.2f", 120 / Double(r.counts[item.key, default: 1])))s")
        }
    }

    /// The Outback profile polls the driver inputs every 0.33 s and the signals under
    /// investigation (coolant, module voltage, timing) every 0.5 s, and they stay close to that
    /// on a link 25 % slower than measured.
    func testOutbackTuningKeepsKeySignalsFast() {
        let plan = carPlan()
        let driver = ["7E0:01:0C", "7E0:01:0D", "7E0:01:10", "7E0:01:11", "7E0:01:49"]
        let watched = ["7E0:01:05", "7E0:01:42", "7E0:01:0E"]
        let key = driver + watched
        for k in driver { XCTAssertEqual(plan.items.first { $0.key == k }?.period, 0.33, k) }
        for k in watched { XCTAssertEqual(plan.items.first { $0.key == k }?.period, 0.5, k) }
        // Generic defaults for comparison (the profile didn't set periods before 2026-10-02).
        var generic = plan
        let oldSSM = ["7E0:A800000113": 2.0, "7E1:A800000056": 2, "7E1:A80000004F": 2, "7E1:A80000004C": 2, "7E1:A80000004D": 5,
                      "7E1:A800000048": 2, "7E1:A800000294": 2, "7E1:A800000295": 2, "7E1:A800000293": 5]
        for i in generic.items.indices {
            if case .mode01(let pid) = generic.items[i].request { generic.items[i].period = StandardPIDs.all[pid]!.period }
            if let p = oldSSM[generic.items[i].key] { generic.items[i].period = p }
        }
        for cost in [0.112, 0.14] {
            let old = run(generic, seconds: 600, requestCost: cost), new = run(plan, seconds: 600, requestCost: cost)
            func period(_ r: (counts: [String: Int], switches: Int, requests: Int, maxPack: Int), _ k: String) -> Double {
                600 / Double(r.counts[k, default: 1])
            }
            print("request cost \(cost)s: \(old.switches) -> \(new.switches) module changes")
            for k in key + ["7E0:01:04", "7E0:01:0B", "7E0:01:0F", "7E0:A800000113", "7E1:A80000004F", "7E1:A800000056"] {
                print("  \(k) \(String(format: "%.2f", period(old, k)))s -> \(String(format: "%.2f", period(new, k)))s")
            }
            for k in key { XCTAssertLessThan(period(new, k), cost < 0.12 ? 0.5 : 0.6, "\(k) at \(cost)s per request") }
            // Fewer module changes than the generic plan.
            XCTAssertLessThan(new.switches, old.switches)
            // Coolant, voltage and timing are polled at least twice as often as before.
            for k in ["7E0:01:05", "7E0:01:42", "7E0:01:0E"] { XCTAssertLessThan(period(new, k) * 2, period(old, k), k) }
            // Nothing starves.
            for item in plan.items { XCTAssertGreaterThan(new.counts[item.key, default: 0], 0, item.key) }
        }
    }

    func testProfilePeriodsYieldToUserSettings() {
        var overrides = PollOverrides()
        overrides.periods["7E0:01:05"] = 4
        let plan = PollPlan.build(supported: [0x05, 0x0C, 0x5C], profile: BuiltInProfiles.profile(id: "subaru-outback-2010-25i-cvt"),
                                  overrides: overrides)
        XCTAssertEqual(plan.items.first { $0.key == "7E0:01:05" }?.period, 4)   // user setting
        XCTAssertEqual(plan.items.first { $0.key == "7E0:01:0C" }?.period, 0.33) // profile
        XCTAssertEqual(plan.items.first { $0.key == "7E0:01:5C" }?.period, 2)   // generic default
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

final class PollModeTests: XCTestCase {
    let stop = PollPlan.Mode(id: "stationary", when: .init(stationaryFor: 3), periods: ["tcm": 30, "both": 10])
    let hot = PollPlan.Mode(id: "hot", when: .init(coolantAtLeast: 98), periods: ["coolant": 0.33, "both": 5])

    func speed(_ v: Double) -> Sample { Sample("speed", v, Date()) }
    func coolant(_ v: Double) -> Sample { Sample("coolant_temp", v, Date()) }

    func testStationaryAfterAWhileAndEndsOnFirstMovement() {
        var t = PollModeTracker(modes: [stop])
        XCTAssertFalse(t.ingest([speed(0)], now: 0))
        XCTAssertFalse(t.ingest([speed(0)], now: 2.9))
        XCTAssertTrue(t.ingest([speed(0)], now: 3))
        XCTAssertEqual(t.active, ["stationary"])
        XCTAssertEqual(t.period(for: "tcm"), 30)
        XCTAssertTrue(t.ingest([speed(1)], now: 3.3))
        XCTAssertEqual(t.active, [])
        XCTAssertNil(t.period(for: "tcm"))
        // A fresh stop starts the wait again.
        XCTAssertFalse(t.ingest([speed(0)], now: 10))
        XCTAssertFalse(t.ingest([speed(0)], now: 12))
        XCTAssertTrue(t.ingest([speed(0)], now: 13))
    }

    func testHotWithHysteresisAndShortestPeriodWins() {
        var t = PollModeTracker(modes: [stop, hot])
        XCTAssertFalse(t.ingest([coolant(97)], now: 0))
        XCTAssertTrue(t.ingest([coolant(98)], now: 1))
        XCTAssertFalse(t.ingest([coolant(96.5)], now: 2))  // still above 98 - 2
        XCTAssertEqual(t.active, ["hot"])
        _ = t.ingest([speed(0)], now: 2)
        XCTAssertTrue(t.ingest([speed(0)], now: 5))
        XCTAssertEqual(t.active, ["hot", "stationary"])
        XCTAssertEqual(t.period(for: "both"), 5)
        XCTAssertEqual(t.period(for: "coolant"), 0.33)
        XCTAssertTrue(t.ingest([coolant(95)], now: 6))
        XCTAssertEqual(t.active, ["stationary"])
    }

    func testPeriodChangeReschedulesFromLastRead() {
        let a = PollItem(header: 0x7E1, request: .profile(id: "a", command: "A800000001"), period: 3)
        var s = Scheduler(items: [a], now: 0)
        let r = s.next(now: 0, currentHeader: nil)!
        s.didSend(r, at: 0)
        s.setPeriod(a.key, 30)      // slowed at a stop
        XCTAssertEqual(s.entries[a.key]?.due, 30)
        s.setPeriod(a.key, 3)       // moving again: due 3 s after the last read, i.e. now
        XCTAssertEqual(s.entries[a.key]?.due, 3)
    }

    func testOutbackModesResolveAndRespectUserSettings() {
        var overrides = PollOverrides()
        overrides.periods["7E1:A80000004F"] = 2
        let plan = PollPlan.build(supported: [0x05, 0x0C, 0x0D, 0x2C, 0x42],
                                  profile: BuiltInProfiles.profile(id: "subaru-outback-2010-25i-cvt"), overrides: overrides)
        let stop = plan.modes.first { $0.id == "stationary" }!, hot = plan.modes.first { $0.id == "hot" }!
        XCTAssertEqual(stop.when.stationaryFor, 3)
        XCTAssertEqual(stop.periods["7E1:A80000004C"], 10)   // lock-up duty
        XCTAssertEqual(stop.periods["7E0:01:2C"], 30)        // EGR, commanded 0 at idle
        XCTAssertNil(stop.periods["7E1:A80000004F"])         // the user set turbine speed
        XCTAssertNil(stop.periods["7E0:01:2D"])              // not supported here
        XCTAssertEqual(hot.periods["7E0:01:05"], 0.33)
        XCTAssertEqual(hot.periods["7E0:01:42"], 0.33)
    }

    func testModeValidation() throws {
        let bad = #"{"format":1,"id":"x","name":"x","modes":[{"id":"m","when":{"stationaryFor":3},"sensorPeriods":{"nope":5}}],"sensors":[]}"#
        XCTAssertThrowsError(try VehicleProfile.decode(Data(bad.utf8)))
        let noCondition = #"{"format":1,"id":"x","name":"x","modes":[{"id":"m","when":{}}],"sensors":[]}"#
        XCTAssertThrowsError(try VehicleProfile.decode(Data(noCondition.utf8)))
    }

    /// What a hot idle at a stop gains, with the measured adapter costs.
    func testHotIdleGetsTheAdapter() {
        let plan = SchedulerTests.outbackPlan()
        var idle = plan
        var tracker = PollModeTracker(modes: plan.modes)
        _ = tracker.ingest([speed(0), coolant(105)], now: 0)
        _ = tracker.ingest([speed(0)], now: 3)
        XCTAssertEqual(tracker.active, ["hot", "stationary"])
        for i in idle.items.indices { if let p = tracker.period(for: idle.items[i].key) { idle.items[i].period = p } }
        let before = SchedulerTests.simulate(plan, seconds: 600), after = SchedulerTests.simulate(idle, seconds: 600)
        func period(_ r: (counts: [String: Int], switches: Int, requests: Int, maxPack: Int), _ k: String) -> Double {
            600 / Double(r.counts[k, default: 1])
        }
        print("hot idle: module changes \(before.switches) -> \(after.switches)")
        for k in ["7E0:01:05", "7E0:01:42", "7E0:01:0C", "7E0:01:0F", "7E0:A800000113", "7E1:A80000004F", "7E1:A800000056"] {
            print("  \(k) \(String(format: "%.2f", period(before, k)))s -> \(String(format: "%.2f", period(after, k)))s")
        }
        XCTAssertLessThan(period(after, "7E0:01:05"), 0.36)
        XCTAssertLessThan(period(after, "7E0:01:42"), 0.36)
        XCTAssertLessThan(after.switches, before.switches / 2)
    }
}
