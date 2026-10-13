import Foundation

/// Turns a sensor's own timestamps into wall-clock dates by anchoring on when its readings
/// arrive. Core Motion stamps readings in seconds since boot, and Apple doesn't say whether
/// that clock runs while the device sleeps, so converting through the system's uptime can be
/// off by hours. Delivery only ever adds delay, so the smallest arrival-minus-timestamp seen
/// is the closest to the true offset; a change of more than a second either way (a different
/// clock base, or a long stall) re-anchors.
public struct SensorClock: Sendable {
    private var offset: Double?
    /// How far an arrival may sit from the current anchor before it re-anchors, seconds.
    public var tolerance: TimeInterval = 1

    public init() {}

    public mutating func date(sensorTime: TimeInterval, arrived: Date) -> Date {
        let candidate = arrived.timeIntervalSince1970 - sensorTime
        if let o = offset, abs(candidate - o) <= tolerance {
            offset = Swift.min(o, candidate)
        } else {
            offset = candidate
        }
        return Date(timeIntervalSince1970: sensorTime + offset!)
    }
}
