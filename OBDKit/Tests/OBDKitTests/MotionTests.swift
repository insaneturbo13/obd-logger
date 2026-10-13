import XCTest
@testable import OBDKit

final class MotionAveragerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testHalfSecondMeansAndBumpPeak() {
        var averager = MotionAverager()
        averager.window = 0.49  // keeps the window edges clear of floating-point ties at 0.02 s steps
        var emitted: [[Sample]] = []
        var bumps: [MotionAverager.Bump] = []
        // 50 Hz, phone upright (gravity along -y), turning slowly, one jolt along gravity at 0.62 s.
        for i in 0...50 {
            let t = t0.addingTimeInterval(Double(i) * 0.02)
            let jolt = i == 31 ? Vec3(0, -0.6, 0) : Vec3(0.01, 0, 0)
            let out = averager.add(.init(time: t, gravity: Vec3(0, -1, 0), acceleration: jolt, rotation: Vec3(0, 0, 0.1)))
            if !out.samples.isEmpty { emitted.append(out.samples) }
            if let b = out.bump { bumps.append(b) }
        }
        XCTAssertEqual(emitted.count, 2)
        let first = Dictionary(uniqueKeysWithValues: emitted[0].map { ($0.signal, $0.value) })
        XCTAssertEqual(emitted[0].count, 11)
        XCTAssertEqual(first[PhoneSignals.gravityY]!, -9.80665, accuracy: 1e-9)
        XCTAssertEqual(first[PhoneSignals.rotationZ]!, 0.1 * 180 / .pi, accuracy: 1e-9)
        XCTAssertEqual(first[PhoneSignals.joltPeak]!, 0, accuracy: 1e-9)
        XCTAssertEqual(first[PhoneSignals.accelX]!, 0.01 * 9.80665, accuracy: 1e-9)
        let second = Dictionary(uniqueKeysWithValues: emitted[1].map { ($0.signal, $0.value) })
        XCTAssertEqual(second[PhoneSignals.joltPeak]!, 0.6 * 9.80665, accuracy: 1e-9)
        XCTAssertGreaterThan(second[PhoneSignals.vibration]!, 1)
        XCTAssertEqual(bumps.count, 1)
        XCTAssertEqual(bumps[0].time.timeIntervalSince(t0), 0.62, accuracy: 1e-6)
        // Each window's samples carry the mean time of its readings.
        XCTAssertEqual(emitted[0][0].time.timeIntervalSince(t0), 0.24, accuracy: 1e-6)
    }

    func testGapStartsAFreshWindowAndBumpsAreSpaced() {
        var averager = MotionAverager()
        var windows = 0, bumps = 0
        func add(_ s: Double, jolt: Bool = false) {
            let out = averager.add(.init(time: t0.addingTimeInterval(s), gravity: Vec3(0, 0, -1),
                                         acceleration: jolt ? Vec3(0, 0, 0.5) : .zero, rotation: .zero))
            if !out.samples.isEmpty { windows += 1 }
            if out.bump != nil { bumps += 1 }
        }
        add(0, jolt: true)
        add(0.6)          // closes window 1 (bump)
        add(0.62, jolt: true)
        add(1.2)          // closes window 2: second jolt 0.62 s after the first, same bump
        add(5.0)          // gap: closes window 3
        add(5.02, jolt: true)
        XCTAssertEqual(averager.flush().bump != nil, true)
        XCTAssertEqual(windows, 3)
        XCTAssertEqual(bumps, 1)
    }
}

final class MountCalibrationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// Deterministic noise.
    struct Noise {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// Vehicle frame (x forward, y right, z down) into a phone in a vent mount: screen facing
    /// the driver, then turned and tilted by the given angles (degrees).
    static func mount(yaw: Double, pitch: Double, roll: Double) -> (Vec3) -> Vec3 {
        let (a, b, c) = (yaw * .pi / 180, pitch * .pi / 180, roll * .pi / 180)
        return { v in
            let base = Vec3(v.y, -v.z, -v.x)
            let rx = Vec3(base.x, cos(c) * base.y - sin(c) * base.z, sin(c) * base.y + cos(c) * base.z)
            let ry = Vec3(cos(b) * rx.x + sin(b) * rx.z, rx.y, -sin(b) * rx.x + cos(b) * rx.z)
            return Vec3(cos(a) * ry.x - sin(a) * ry.y, sin(a) * ry.x + cos(a) * ry.y, ry.z)
        }
    }

    static func grade(atDistance s: Double) -> Double {
        let p = s.truncatingRemainder(dividingBy: 3000)
        if p >= 1000 && p < 1600 { return 4 }
        if p >= 2000 && p < 2500 { return -3 }
        return 0
    }

    struct Truth {
        var pitch: [Date: Double] = [:]
        var grade: [Date: Double] = [:]
        var longitudinal: [Date: Double] = [:]
        var yaw: [Date: Double] = [:]
        var speed: [Date: Double] = [:]
    }

    /// A drive of stop-start cycles over hills, with right and left turns, recorded by a phone
    /// in `mounts` (each used for `minutesEach`), with a few seconds of handling in between.
    /// `flipAcceleration` delivers acceleration with the opposite sign (as if the sensor
    /// convention were misread); `dropout` (seconds) loses every reading for a while and then
    /// resumes the trip as a new connection, restarting the barometer's relative altitude.
    func drive(mounts: [(Vec3) -> Vec3], minutesEach: Double, steady: Bool = false, barometer: Bool = true,
               flipAcceleration: Bool = false, dropout: ClosedRange<Double>? = nil) -> (TripData, Truth) {
        var series: [SignalID: [TimedValue]] = [:]
        var truth = Truth()
        var noise = Noise()
        var lost = false
        func add(_ id: SignalID, _ t: Date, _ v: Double) {
            if !lost { series[id, default: []].append(TimedValue(t, v)) }
        }
        var t = 0.0, s = 0.0, v = 0.0
        let dt = 0.5
        var nextSpeed = 0.0, nextAlt = 0.0
        var altitudeZero: Double?
        for (mi, mount) in mounts.enumerated() {
            let end = t + minutesEach * 60
            while t < end {
                lost = dropout?.contains(t) ?? false
                if let d = dropout, t >= d.upperBound, altitudeZero == nil { altitudeZero = altitude(s) }
                let cycle = t.truncatingRemainder(dividingBy: 68), k = Int(t / 68)
                var a = 0.0
                if steady { v = 20 } else if cycle < 10 { a = 2; v = 2 * cycle } else if cycle < 50 { v = 20 }
                else if cycle < 58 { a = -2.5; v = 20 - 2.5 * (cycle - 50) } else { v = 0 }
                var yaw = 0.0
                if cycle >= 25 && cycle < 31 { yaw = k % 3 == 1 ? 10 : k % 3 == 2 ? -10 : 0 }
                let lat = v * yaw * .pi / 180
                let g = Self.grade(atDistance: s), theta = atan(g / 100)
                let date = t0.addingTimeInterval(t)
                let gravityBody = Vec3(-sin(theta), 0, cos(theta)) * 9.80665
                let accelBody = Vec3(a + 0.2 * noise.next(), lat + 0.2 * noise.next(), 0.5 * noise.next())
                let gd = mount(gravityBody), ad = mount(accelBody) * (flipAcceleration ? -1 : 1), wd = mount(Vec3(0, 0, yaw))
                for (ids, vec) in [(PhoneSignals.gravity, gd), (PhoneSignals.acceleration, ad), (PhoneSignals.rotation, wd)] {
                    add(ids[0], date, vec.x); add(ids[1], date, vec.y); add(ids[2], date, vec.z)
                }
                truth.pitch[date] = theta * 180 / .pi
                truth.grade[date] = g
                truth.longitudinal[date] = a
                truth.yaw[date] = yaw
                truth.speed[date] = v * 3.6
                // OBD road speed: whole km/h, about three times a second.
                while nextSpeed <= t { add("speed", t0.addingTimeInterval(nextSpeed), (v * 3.6).rounded()); nextSpeed += 0.33 }
                if barometer {
                    while nextAlt <= t {
                        add(PhoneSignals.relativeAltitude, t0.addingTimeInterval(nextAlt),
                            altitude(s) - (altitudeZero ?? 0) + 0.1 * noise.next() + t / 3600)
                        nextAlt += 1
                    }
                }
                s += v * dt
                t += dt
            }
            if mi < mounts.count - 1 {
                // Picked up and put back: 10 s of the phone pointing anywhere.
                for _ in 0..<20 {
                    let date = t0.addingTimeInterval(t)
                    let r = Vec3(noise.next(), noise.next(), noise.next()).normalized ?? Vec3(1, 0, 0)
                    for (ids, vec) in [(PhoneSignals.gravity, r * 9.8), (PhoneSignals.acceleration, Vec3.zero), (PhoneSignals.rotation, Vec3.zero)] {
                        add(ids[0], date, vec.x); add(ids[1], date, vec.y); add(ids[2], date, vec.z)
                    }
                    t += dt
                }
                nextSpeed = t
                nextAlt = t
            }
        }
        var meta = TripMeta(id: "drive", startedAt: t0, appVersion: "test")
        if let d = dropout {
            meta.segments[0].end = t0.addingTimeInterval(d.lowerBound)
            meta.segments.append(TripMeta.Segment(start: t0.addingTimeInterval(d.upperBound), end: nil))
        }
        return (TripData(meta: meta, series: series), truth)
    }

    /// Altitude after `s` meters of the grade profile.
    func altitude(_ s: Double) -> Double {
        var h = 0.0, x = 0.0
        while x < s {
            let step = Swift.min(10, s - x)
            h += Self.grade(atDistance: x) / 100 * step
            x += step
        }
        return h
    }

    func rms(_ errors: [Double]) -> Double { (errors.map { $0 * $0 }.reduce(0, +) / Double(Swift.max(1, errors.count))).squareRoot() }

    func values(_ r: MountCalibration.Result, _ id: SignalID) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for s in r.samples where s.signal == id { out[s.time] = s.value }
        return out
    }

    func testRecoversPitchAccelerationAndYawFromATiltedMount() {
        let (trip, truth) = drive(mounts: [Self.mount(yaw: 20, pitch: -12, roll: 5)], minutesEach: 15)
        let result = MountCalibration.compute(trip)
        XCTAssertEqual(result.stretches.count, 1)
        XCTAssertGreaterThan(result.stretches[0].forwardMatch ?? 0, 0.8)
        XCTAssertNotNil(result.stretches[0].pitchOffset)
        XCTAssertGreaterThan(result.stretches[0].gradeMatch ?? 0, 0.8)
        XCTAssertFalse(result.stretches[0].tiltFlipped)

        let pitch = values(result, PhoneSignals.pitch)
        let moving = pitch.keys.filter { (truth.speed[$0] ?? 0) >= 15 }
        XCTAssertGreaterThan(moving.count, 1000)
        XCTAssertLessThan(rms(moving.map { pitch[$0]! - truth.pitch[$0]! }), 0.3)

        let long = values(result, PhoneSignals.longitudinal)
        XCTAssertLessThan(rms(long.keys.map { long[$0]! - truth.longitudinal[$0]! }), 0.35)

        let yaw = values(result, PhoneSignals.yawRate)
        let rightTurns = yaw.keys.filter { truth.yaw[$0] == 10 }
        XCTAssertFalse(rightTurns.isEmpty)
        for d in rightTurns { XCTAssertEqual(yaw[d]!, 10, accuracy: 0.5) }
        let lat = values(result, PhoneSignals.lateral)
        XCTAssertGreaterThan(rightTurns.map { lat[$0]! }.reduce(0, +) / Double(rightTurns.count), 3)

        // Grade from the barometer, away from the start and end of each hill.
        let grade = values(result, PhoneSignals.grade)
        XCTAssertGreaterThan(grade.count, 300)
        let steady = grade.keys.filter { d in
            let s = truth.grade[d]
            return [-6.0, -3, 3, 6].allSatisfy { truth.grade[d.addingTimeInterval($0)] == s }
        }
        let errors = steady.map { abs(grade[$0]! - truth.grade[$0]!) }.sorted()
        XCTAssertLessThan(errors[errors.count / 2], 0.5)
        XCTAssertTrue(result.summary.contains("pitch zero from barometer"))
    }

    func testAccelerationWithTheOppositeSignIsCaughtByTheBarometer() {
        let (trip, truth) = drive(mounts: [Self.mount(yaw: 20, pitch: -12, roll: 5)], minutesEach: 15, flipAcceleration: true)
        let result = MountCalibration.compute(trip)
        XCTAssertEqual(result.stretches.count, 1)
        XCTAssertTrue(result.stretches[0].tiltFlipped)
        XCTAssertGreaterThan(result.stretches[0].gradeMatch ?? 0, 0.8)
        let pitch = values(result, PhoneSignals.pitch)
        let moving = pitch.keys.filter { (truth.speed[$0] ?? 0) >= 15 }
        XCTAssertLessThan(rms(moving.map { pitch[$0]! - truth.pitch[$0]! }), 0.3)
        // Acceleration follows the speed changes whatever the sensor's sign.
        let long = values(result, PhoneSignals.longitudinal)
        XCTAssertLessThan(rms(long.keys.map { long[$0]! - truth.longitudinal[$0]! }), 0.35)
        XCTAssertTrue(result.summary.contains("tilt sign turned round"))
    }

    func testGradeNeverSpansADropoutOrAResume() {
        // 12 s with no readings at all, then a new connection: the barometer starts again at zero.
        let (trip, truth) = drive(mounts: [Self.mount(yaw: 20, pitch: -12, roll: 5)], minutesEach: 10,
                                  dropout: 170...182)
        let result = MountCalibration.compute(trip)
        let grade = values(result, PhoneSignals.grade)
        let resume = t0.addingTimeInterval(182)
        let near = grade.keys.filter { abs($0.timeIntervalSince(resume)) < 30 }
        for d in near { XCTAssertEqual(grade[d]!, truth.grade[d]!, accuracy: 1.5, "grade at \(d.timeIntervalSince(t0)) s") }
        XCTAssertGreaterThan(grade.count, 200)
    }

    func testPhoneMovedInItsMountStartsANewStretch() {
        let (trip, truth) = drive(mounts: [Self.mount(yaw: 20, pitch: -12, roll: 5), Self.mount(yaw: -35, pitch: 25, roll: -10)],
                                  minutesEach: 8)
        let result = MountCalibration.compute(trip)
        XCTAssertEqual(result.stretches.count, 2)
        XCTAssertTrue(result.stretches.allSatisfy { ($0.forwardMatch ?? 0) > 0.8 })
        let pitch = values(result, PhoneSignals.pitch)
        let moving = pitch.keys.filter { (truth.speed[$0] ?? 0) >= 15 }
        XCTAssertLessThan(rms(moving.map { pitch[$0]! - truth.pitch[$0]! }), 0.4)
    }

    func testSteadyCruiseGivesYawAndGradeButNoPitch() {
        let (trip, _) = drive(mounts: [Self.mount(yaw: 10, pitch: 0, roll: 0)], minutesEach: 6, steady: true)
        let result = MountCalibration.compute(trip)
        XCTAssertEqual(result.stretches.count, 1)
        XCTAssertNil(result.stretches[0].forwardMatch)
        XCTAssertTrue(values(result, PhoneSignals.pitch).isEmpty)
        XCTAssertFalse(values(result, PhoneSignals.yawRate).isEmpty)
        XCTAssertFalse(values(result, PhoneSignals.grade).isEmpty)
        XCTAssertTrue(result.summary.contains("forward not found"))
    }

    func testWithoutABarometerPitchIsRelative() {
        let (trip, _) = drive(mounts: [Self.mount(yaw: 0, pitch: -5, roll: 0)], minutesEach: 6, barometer: false)
        let result = MountCalibration.compute(trip)
        XCTAssertNotNil(result.stretches.first?.forwardMatch)
        XCTAssertNil(result.stretches.first?.pitchOffset)
        XCTAssertTrue(values(result, PhoneSignals.grade).isEmpty)
        XCTAssertFalse(values(result, PhoneSignals.pitch).isEmpty)
    }

    func testApplyWritesAndReplacesVehicleMotion() throws {
        let root = try Fixtures.tempDirectory()
        let (drive, _) = drive(mounts: [Self.mount(yaw: 20, pitch: -12, roll: 5)], minutesEach: 4)
        let rec = try TripRecorder.start(root: root, meta: TripMeta(id: "trip", startedAt: t0, appVersion: "test"), traceEnabled: false)
        for (id, values) in drive.series { rec.record(values.map { Sample(id, $0.value, $0.time) }) }
        rec.finish(at: t0.addingTimeInterval(240))

        var trip = try TripData.load(rec.directory)
        let summary = try MountCalibration.apply(to: &trip, directory: rec.directory)
        XCTAssertNotNil(summary)
        let pitchCount = trip.series[PhoneSignals.pitch]?.count ?? 0
        XCTAssertGreaterThan(pitchCount, 400)
        XCTAssertTrue(trip.meta.signals.contains { $0.id == PhoneSignals.pitch })

        // Running it again (a resumed trip ending) replaces rather than duplicates.
        var again = try TripData.load(rec.directory)
        XCTAssertEqual(again.series[PhoneSignals.pitch]?.count, pitchCount)
        try MountCalibration.apply(to: &again, directory: rec.directory)
        XCTAssertEqual(again.series[PhoneSignals.pitch]?.count, pitchCount)
        XCTAssertEqual(try TripData.load(rec.directory).series[PhoneSignals.pitch]?.count, pitchCount)
    }

    func testTripWithoutPhoneMotionIsLeftAlone() throws {
        var trip = TripData(meta: TripMeta(id: "t", startedAt: t0, appVersion: "test"),
                            series: ["speed": [TimedValue(t0, 50)]])
        XCTAssertNil(try MountCalibration.apply(to: &trip, directory: nil))
        XCTAssertNil(trip.series[PhoneSignals.pitch])
    }

    func testRotationRateUnit() {
        let d = UnitConverter.display(12.34, unit: .degreesPerSecond, prefs: .us)
        XCTAssertEqual(d.textWithUnit, "12.3 °/s")
        XCTAssertEqual(ImportUnit.parse("°/s")?.base, .degreesPerSecond)
    }
}
