import Foundation

/// Turns the device's motion readings (tens per second) into one set of samples per window:
/// the mean gravity, acceleration and rotation in the device's frame, plus the peak and RMS
/// of the acceleration along gravity. A mean alone would smooth bumps away; the peak keeps
/// them, and a mount that bounces a little only shakes the acceleration, not the gravity
/// direction the tilt comes from.
public struct MotionAverager: Sendable {
    public struct Reading: Sendable, Equatable {
        public var time: Date
        /// Gravity in g, pointing toward the ground (Core Motion's `gravity`).
        public var gravity: Vec3
        /// The device's own acceleration in g, + along the axis it speeds up in (Core Motion's
        /// `userAcceleration` negated).
        public var acceleration: Vec3
        /// Rotation rate in rad/s.
        public var rotation: Vec3

        public init(time: Date, gravity: Vec3, acceleration: Vec3, rotation: Vec3) {
            self.time = time
            self.gravity = gravity
            self.acceleration = acceleration
            self.rotation = rotation
        }
    }

    /// A jolt along gravity at or above `bumpThreshold`.
    public struct Bump: Sendable, Equatable {
        public let time: Date
        /// m/s²
        public let peak: Double
    }

    public static let standardGravity = 9.80665

    public var window: TimeInterval = 0.5
    /// Vertical jolt that counts as a large bump, m/s² (0.4 g).
    public var bumpThreshold = 4.0
    /// One bump per this many seconds: a pothole shakes the car for a moment.
    public var bumpSpacing: TimeInterval = 2
    /// Readings further apart than this (the app was paused) start a fresh window.
    public var maxGap: TimeInterval = 1

    private var count = 0
    private var timeSum = 0.0
    private var gravitySum = Vec3.zero
    private var accelSum = Vec3.zero
    private var rotationSum = Vec3.zero
    private var verticalSquares = 0.0
    private var peak = 0.0
    private var peakTime: Date?
    private var windowStart: Date?
    private var lastTime: Date?
    private var lastBump: Date?

    public init() {}

    /// Adds one reading; returns the previous window's samples when this reading closes it,
    /// and a bump if that window held one.
    public mutating func add(_ r: Reading) -> (samples: [Sample], bump: Bump?) {
        var out: (samples: [Sample], bump: Bump?) = ([], nil)
        if let start = windowStart, let last = lastTime,
           r.time.timeIntervalSince(start) >= window || r.time.timeIntervalSince(last) > maxGap || r.time < last {
            out = close()
        }
        if windowStart == nil { windowStart = r.time }
        lastTime = r.time
        let g = Self.standardGravity
        count += 1
        timeSum += r.time.timeIntervalSince1970
        gravitySum += r.gravity * g
        accelSum += r.acceleration * g
        rotationSum += r.rotation * (180 / .pi)
        if let down = r.gravity.normalized {
            let vertical = r.acceleration.dot(down) * g
            verticalSquares += vertical * vertical
            if abs(vertical) > peak {
                peak = abs(vertical)
                peakTime = r.time
            }
        }
        return out
    }

    /// Emits whatever the current window holds (at the end of recording).
    public mutating func flush() -> (samples: [Sample], bump: Bump?) { close() }

    private mutating func close() -> (samples: [Sample], bump: Bump?) {
        defer {
            count = 0
            timeSum = 0
            gravitySum = .zero
            accelSum = .zero
            rotationSum = .zero
            verticalSquares = 0
            peak = 0
            peakTime = nil
            windowStart = nil
        }
        guard count > 0 else { return ([], nil) }
        let n = Double(count)
        let t = Date(timeIntervalSince1970: timeSum / n)
        let gm = gravitySum * (1 / n), am = accelSum * (1 / n), wm = rotationSum * (1 / n)
        var samples: [Sample] = []
        for (ids, v) in [(PhoneSignals.gravity, gm), (PhoneSignals.acceleration, am), (PhoneSignals.rotation, wm)] {
            samples.append(Sample(ids[0], v.x, t))
            samples.append(Sample(ids[1], v.y, t))
            samples.append(Sample(ids[2], v.z, t))
        }
        samples.append(Sample(PhoneSignals.joltPeak, peak, t))
        samples.append(Sample(PhoneSignals.vibration, (verticalSquares / n).squareRoot(), t))
        var bump: Bump?
        if peak >= bumpThreshold, let at = peakTime, lastBump.map({ at.timeIntervalSince($0) >= bumpSpacing }) ?? true {
            bump = Bump(time: at, peak: peak)
            lastBump = at
        }
        return (samples, bump)
    }
}
