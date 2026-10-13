import Foundation

/// Works out how the phone sits in the car from a whole trip, then expresses its motion in
/// the car's frame: pitch (nose up +), roll (leaning right +), longitudinal acceleration
/// (speeding up +), lateral acceleration (toward the right, i.e. turning right +) and yaw
/// rate (turning right +). Also the road grade from the barometer, which needs no mount.
///
/// - Down is the average gravity direction while the phone stayed put.
/// - Forward is the direction in which the phone's acceleration follows the car's change of
///   speed (OBD speed, or GPS speed without it), so it needs a few starts and stops.
/// - Pitch zero comes from the barometer's road grade averaged over the same stretch. Without
///   a barometer, pitch is relative to the stretch's average, and so is roll always (a road's
///   crown leans the car a little all the time).
/// - Pitch is also checked against the barometer's grade: they should rise and fall together.
///   Forward comes from accelerations, so if those ever arrived with the opposite sign, pitch
///   and roll would be backwards; the check turns them round. Acceleration needs no check,
///   since its axis is defined by the speed changes themselves.
///
/// A phone moved in its mount (or picked up) starts a new stretch, each calibrated on its own;
/// stretches shorter than `minimumStretch` are left out.
public enum MountCalibration {
    public struct Stretch: Sendable, Equatable {
        public var start: Date
        public var end: Date
        /// How closely the phone's forward acceleration followed the speed changes (0–1);
        /// nil when the forward direction couldn't be found.
        public var forwardMatch: Double?
        /// Degrees added to put pitch on the barometer's grade; nil without a barometer.
        public var pitchOffset: Double?
        /// Correlation of pitch with the barometer's grade (near 1 when the tilt is right); nil
        /// without a barometer or without enough hill to tell.
        public var gradeMatch: Double?
        /// Pitch and roll came out opposite to the barometer's grade and were turned round.
        public var tiltFlipped = false
    }

    public struct Result: Sendable {
        public var samples: [Sample]
        public var stretches: [Stretch]
        /// One line for the trip's meta.json.
        public var summary: String
    }

    /// Shortest stretch with the phone in one position that gets calibrated, seconds.
    public static let minimumStretch: TimeInterval = 60
    /// Change in gravity direction that means the phone moved in (or out of) its mount.
    public static let mountMoveDegrees = 15.0
    /// Speed changes (seconds with more than 0.5 m/s²) needed to trust the forward direction.
    public static let minimumSpeedChanges = 20
    public static let minimumForwardMatch = 0.4
    /// Distance over which the barometer's altitude change becomes a grade, meters.
    public static let gradeSpan = 80.0

    struct Frame {
        let t: Date
        let gravity: Vec3
        let accel: Vec3
        let rotation: Vec3
    }

    /// Recomputes the vehicle-frame signals for `trip`, replacing earlier ones in memory and,
    /// with a directory, in its vehicle-motion.csv. Returns the summary line, or nil for a
    /// trip without phone motion data.
    @discardableResult
    public static func apply(to trip: inout TripData, directory: URL?) throws -> String? {
        for info in PhoneSignals.calibrated { trip.series[info.id] = nil }
        let result = compute(trip)
        guard !result.samples.isEmpty || !result.stretches.isEmpty else { return nil }
        for s in result.samples { trip.series[s.signal, default: []].append(TimedValue(s.time, s.value)) }
        for info in PhoneSignals.calibrated where !trip.meta.signals.contains(where: { $0.id == info.id }) {
            trip.meta.signals.append(info)
        }
        trip.meta.signals.sort { $0.id < $1.id }
        if let directory { try TripFiles.writeVehicleMotion(result.samples, to: directory) }
        return result.summary
    }

    public static func compute(_ trip: TripData) -> Result {
        let obdSpeed = trip.series["speed"] ?? []
        let speed = Series(obdSpeed.count >= 10 ? obdSpeed : trip.series[GPSSignals.speed] ?? [])
        let altitudeValues = trip.series[PhoneSignals.relativeAltitude].flatMap { $0.count >= 10 ? $0 : nil }
            ?? trip.series[PhoneSignals.altitude] ?? []
        let gradeSamples = grade(altitude: Series(altitudeValues), speed: speed,
                                 breaks: trip.meta.segments.map { $0.start.timeIntervalSince1970 })
        let grade = Series(gradeSamples.map { TimedValue($0.time, $0.value) })

        var samples = gradeSamples
        var stretches: [Stretch] = []
        var lines: [String] = []
        for frames in split(frames(trip)) {
            guard let first = frames.first, let last = frames.last,
                  last.t.timeIntervalSince(first.t) >= minimumStretch else { continue }
            let (out, stretch) = calibrate(frames, speed: speed, grade: grade)
            samples += out
            stretches.append(stretch)
            lines.append(describe(stretch))
        }
        samples.sort { $0.time != $1.time ? $0.time < $1.time : $0.signal < $1.signal }
        var summary = stretches.isEmpty ? "Phone motion: no stretch of a minute or more with the phone held still."
            : "Phone mount: " + lines.joined(separator: "; ") + "."
        if !gradeSamples.isEmpty { summary += " Road grade from the barometer." }
        return Result(samples: samples, stretches: stretches, summary: summary)
    }

    static func describe(_ s: Stretch) -> String {
        let minutes = Int((s.end.timeIntervalSince(s.start) / 60).rounded())
        var text = "\(minutes) min"
        if let m = s.forwardMatch {
            text += ", forward found (match \(String(format: "%.2f", m)))"
            if let o = s.pitchOffset { text += ", pitch zero from barometer (\(String(format: "%+.1f", o))°)" }
            else { text += ", pitch relative to this stretch's average" }
            if let r = s.gradeMatch { text += ", pitch follows barometer grade (r \(String(format: "%.2f", r)))" }
            if s.tiltFlipped { text += ", tilt sign turned round to match the barometer" }
        } else {
            text += ", forward not found (too few clear speed changes): yaw rate only"
        }
        return text
    }

    // MARK: steps

    /// The phone's half-second readings, joined on their shared timestamps.
    static func frames(_ trip: TripData) -> [Frame] {
        let ids = PhoneSignals.gravity + PhoneSignals.acceleration + PhoneSignals.rotation
        let columns: [[Int64: Double]] = ids.map { id in
            var d: [Int64: Double] = [:]
            for v in trip.series[id] ?? [] { d[Int64((v.time.timeIntervalSince1970 * 1000).rounded())] = v.value }
            return d
        }
        var out: [Frame] = []
        for ms in columns[0].keys.sorted() {
            let v = columns.compactMap { $0[ms] }
            guard v.count == ids.count else { continue }
            out.append(Frame(t: Date(timeIntervalSince1970: Double(ms) / 1000),
                             gravity: Vec3(v[0], v[1], v[2]), accel: Vec3(v[3], v[4], v[5]), rotation: Vec3(v[6], v[7], v[8])))
        }
        return out
    }

    /// Splits where the phone was moved: its gravity direction (smoothed over 3 s) leaves the
    /// stretch's average by more than `mountMoveDegrees`, or readings stop for two minutes.
    static func split(_ frames: [Frame]) -> [[Frame]] {
        var out: [[Frame]] = []
        var current: [Frame] = []
        var sum = Vec3.zero
        var recent: [Vec3] = []
        func finish() {
            if !current.isEmpty { out.append(current) }
            current = []
            sum = .zero
            recent = []
        }
        for f in frames {
            guard let u = f.gravity.normalized else { continue }
            if let last = current.last, f.t.timeIntervalSince(last.t) > 120 { finish() }
            recent.append(u)
            if recent.count > 6 { recent.removeFirst() }
            let smooth = recent.reduce(Vec3.zero, +)
            if current.count >= 6, smooth.angle(to: sum) > mountMoveDegrees {
                // The last few readings were already on the move; leave them out.
                current.removeLast(Swift.min(current.count, 5))
                finish()
                recent = [u]
            }
            current.append(f)
            sum += u
        }
        finish()
        return out
    }

    static func calibrate(_ frames: [Frame], speed: Series, grade: Series) -> ([Sample], Stretch) {
        let down = frames.reduce(Vec3.zero) { $0 + ($1.gravity.normalized ?? .zero) }.normalized ?? Vec3(0, 0, -1)
        var stretch = Stretch(start: frames.first!.t, end: frames.last!.t, forwardMatch: nil, pitchOffset: nil)

        // Forward: correlate the phone's acceleration with the change of road speed.
        var pairs: [(accel: Vec3, ref: Double)] = []
        for f in frames {
            let t = f.t.timeIntervalSince1970
            guard let v = speed.at(t), v >= 8, let before = speed.at(t - 1), let after = speed.at(t + 1) else { continue }
            pairs.append((f.accel, (after - before) / 3.6 / 2))
        }
        var forward: Vec3?
        let changes = pairs.filter { abs($0.ref) > 0.5 }.count
        if changes >= minimumSpeedChanges {
            let m = pairs.reduce(Vec3.zero) { $0 + $1.accel * $1.ref }
            if let f = (m - down * m.dot(down)).normalized {
                var sxy = 0.0, sxx = 0.0, syy = 0.0
                for p in pairs {
                    let x = p.accel.dot(f)
                    sxy += x * p.ref
                    sxx += x * x
                    syy += p.ref * p.ref
                }
                let match = sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
                if match >= minimumForwardMatch {
                    forward = f
                    stretch.forwardMatch = match
                }
            }
        }

        var out: [Sample] = []
        out.reserveCapacity(frames.count * 5)
        for f in frames { out.append(Sample(PhoneSignals.yawRate, f.rotation.dot(down), f.t)) }
        guard let forward, let right = down.cross(forward).normalized else { return (out, stretch) }

        func degrees(_ x: Double) -> Double { asin(Swift.min(1, Swift.max(-1, x))) * 180 / .pi }
        var rawPitch = frames.map { f in degrees(-(f.gravity.normalized ?? down).dot(forward)) }
        // Frames with a barometric grade: (frame index, grade as an angle in degrees).
        var graded: [(index: Int, angle: Double)] = []
        for (i, f) in frames.enumerated() {
            let t = f.t.timeIntervalSince1970
            guard let v = speed.at(t), v >= 15, let g = grade.at(t) else { continue }
            graded.append((i, atan(g / 100) * 180 / .pi))
        }
        // Pitch should rise with the grade; with enough hill to tell, turn it round if it falls.
        var tiltRight = right
        if graded.count >= 120, let r = correlation(graded.map { rawPitch[$0.index] }, graded.map { $0.angle }) {
            stretch.gradeMatch = r
            if r <= -0.5 {
                rawPitch = rawPitch.map { -$0 }
                tiltRight = right * -1
                stretch.tiltFlipped = true
                stretch.gradeMatch = -r
            }
        }
        let offsets = graded.map { $0.angle - rawPitch[$0.index] }
        let offset = offsets.count >= 30 ? offsets.reduce(0, +) / Double(offsets.count) : 0
        if offsets.count >= 30 { stretch.pitchOffset = offset }

        for (i, f) in frames.enumerated() {
            let g = f.gravity.normalized ?? down
            out.append(Sample(PhoneSignals.pitch, rawPitch[i] + offset, f.t))
            out.append(Sample(PhoneSignals.roll, degrees(g.dot(tiltRight)), f.t))
            out.append(Sample(PhoneSignals.longitudinal, f.accel.dot(forward), f.t))
            out.append(Sample(PhoneSignals.lateral, f.accel.dot(right), f.t))
        }
        return (out, stretch)
    }

    /// Road grade (%) from barometric altitude over `gradeSpan` meters of travel, at each
    /// altitude reading taken above 15 km/h. A window never spans a gap of more than 5 s in the
    /// speed or altitude readings, or one of `breaks` (the starts of the trip's connections: a
    /// resumed trip restarts the barometer's relative altitude at zero).
    static func grade(altitude: Series, speed: Series, breaks: [Double] = []) -> [Sample] {
        guard altitude.count >= 10, speed.count >= 10 else { return [] }
        // Distance traveled at each speed reading (no distance across gaps over 5 s), and which
        // unbroken run of readings each one belongs to.
        var distance = [0.0], speedRun = [0]
        distance.reserveCapacity(speed.count)
        speedRun.reserveCapacity(speed.count)
        for i in 1..<speed.count {
            let dt = speed.t[i] - speed.t[i - 1]
            let joined = dt > 0 && dt <= 5
            distance.append(distance[i - 1] + (joined ? (speed.v[i] + speed.v[i - 1]) / 2 / 3.6 * dt : 0))
            speedRun.append(speedRun[i - 1] + (joined ? 0 : 1))
        }
        var altitudeRun = [0]
        altitudeRun.reserveCapacity(altitude.count)
        for i in 1..<altitude.count {
            let dt = altitude.t[i] - altitude.t[i - 1]
            altitudeRun.append(altitudeRun[i - 1] + (dt > 0 && dt <= 5 ? 0 : 1))
        }
        func unbroken(_ a: Double, _ b: Double) -> Bool {
            speed.run(speedRun, at: a) == speed.run(speedRun, at: b)
                && altitude.run(altitudeRun, at: a) == altitude.run(altitudeRun, at: b)
                && breaks.filter({ $0 <= a }).count == breaks.filter({ $0 <= b }).count
        }
        let traveled = Series(t: speed.t, v: distance)
        let half = gradeSpan / 2
        var out: [Sample] = []
        for i in 0..<altitude.count {
            let t = altitude.t[i]
            guard let v = speed.at(t), v >= 15, let s = traveled.at(t),
                  let t1 = traveled.time(reaching: s - half), let t2 = traveled.time(reaching: s + half),
                  t2 - t1 <= 30, unbroken(t1, t2), let a1 = altitude.at(t1), let a2 = altitude.at(t2),
                  let s1 = traveled.at(t1), let s2 = traveled.at(t2), s2 - s1 > half else { continue }
            out.append(Sample(PhoneSignals.grade, (a2 - a1) / (s2 - s1) * 100, Date(timeIntervalSince1970: t)))
        }
        return out
    }

    /// Pearson correlation; nil when either side doesn't vary.
    static func correlation(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 2 else { return nil }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// A time series as plain arrays (seconds since 1970) with interpolation.
    struct Series {
        let t: [Double]
        let v: [Double]
        var count: Int { t.count }

        init(t: [Double], v: [Double]) {
            self.t = t
            self.v = v
        }

        init(_ values: [TimedValue]) {
            t = values.map { $0.time.timeIntervalSince1970 }
            v = values.map(\.value)
        }

        /// Linear interpolation between the readings around `x`, if they're within `maxGap` of it.
        func at(_ x: Double, maxGap: Double = 3) -> Double? {
            guard let first = t.first, let last = t.last, x >= first - maxGap, x <= last + maxGap else { return nil }
            var lo = 0, hi = t.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if t[mid] < x { lo = mid + 1 } else { hi = mid }
            }
            if t[lo] == x { return v[lo] }
            if lo == 0 { return t[0] - x <= maxGap ? v[0] : nil }
            if t[lo] < x { return x - t[lo] <= maxGap ? v[lo] : nil }
            let a = lo - 1
            guard x - t[a] <= maxGap, t[lo] - x <= maxGap else { return nil }
            return v[a] + (v[lo] - v[a]) * (x - t[a]) / (t[lo] - t[a])
        }

        /// `runs[i]` for the first reading at or after `x` (the last reading when `x` is past the end).
        func run(_ runs: [Int], at x: Double) -> Int {
            var lo = 0, hi = t.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if t[mid] < x { lo = mid + 1 } else { hi = mid }
            }
            return runs[lo]
        }

        /// First time a non-decreasing series reaches `value` (interpolated).
        func time(reaching value: Double) -> Double? {
            guard let first = v.first, let last = v.last, value >= first, value <= last else { return nil }
            var lo = 0, hi = v.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if v[mid] < value { lo = mid + 1 } else { hi = mid }
            }
            if lo == 0 || v[lo] == value { return t[lo] }
            let a = lo - 1
            return t[a] + (t[lo] - t[a]) * (value - v[a]) / (v[lo] - v[a])
        }
    }
}
