import Foundation

/// A 3-vector for motion-sensor math (device or vehicle frame).
public struct Vec3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, k: Double) -> Vec3 { Vec3(a.x * k, a.y * k, a.z * k) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { dot(self).squareRoot() }
    /// Unit vector in the same direction; nil for a zero vector.
    public var normalized: Vec3? { length > 1e-12 ? self * (1 / length) : nil }

    /// Angle to another vector, in degrees.
    public func angle(to b: Vec3) -> Double {
        guard let u = normalized, let v = b.normalized else { return 0 }
        return acos(Swift.min(1, Swift.max(-1, u.dot(v)))) * 180 / .pi
    }
}
