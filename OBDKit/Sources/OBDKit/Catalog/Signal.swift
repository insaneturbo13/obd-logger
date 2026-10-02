import Foundation

/// Stable identifier of one measured or derived quantity, e.g. "coolant_temp". Used as the
/// column/field name in recordings and exports.
public struct SignalID: Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func < (a: SignalID, b: SignalID) -> Bool { a.rawValue < b.rawValue }
}

public enum SignalCategory: String, Codable, Sendable, CaseIterable {
    case engine, temperatures, airFuel, throttle, drivetrain, electrical, emissions, fuel, status, location, derived
}

public enum SignalSource: String, Codable, Sendable {
    case standard, profile, derived, gps, adapter
}

public struct SignalInfo: Codable, Sendable, Equatable {
    public let id: SignalID
    public var name: String
    public var unit: BaseUnit
    public var category: SignalCategory
    public var source: SignalSource
    /// Typical display span in base units, for gauges. nil = no sensible fixed span.
    public var range: ClosedRange<Double>?
    /// Profile entries carry a verification status ("verified", "candidate", ...).
    public var status: String?

    public init(id: SignalID, name: String, unit: BaseUnit, category: SignalCategory, source: SignalSource,
                range: ClosedRange<Double>? = nil, status: String? = nil) {
        self.id = id
        self.name = name
        self.unit = unit
        self.category = category
        self.source = source
        self.range = range
        self.status = status
    }
}

/// One measured value at the moment its reply arrived.
public struct Sample: Sendable, Equatable {
    public let signal: SignalID
    public let value: Double
    public let time: Date

    public init(_ signal: SignalID, _ value: Double, _ time: Date) {
        self.signal = signal
        self.value = value
        self.time = time
    }
}

/// Signals that don't come from the car.
public enum GPSSignals {
    public static let latitude: SignalID = "gps_lat"
    public static let longitude: SignalID = "gps_lon"
    public static let speed: SignalID = "gps_speed"
    public static let altitude: SignalID = "gps_alt"
    public static let course: SignalID = "gps_course"
    public static let accuracy: SignalID = "gps_hacc"

    public static let infos: [SignalInfo] = [
        SignalInfo(id: latitude, name: "Latitude", unit: .coordinate, category: .location, source: .gps),
        SignalInfo(id: longitude, name: "Longitude", unit: .coordinate, category: .location, source: .gps),
        SignalInfo(id: speed, name: "GPS speed", unit: .kmh, category: .location, source: .gps, range: 0...160),
        SignalInfo(id: altitude, name: "GPS altitude", unit: .meters, category: .location, source: .gps),
        SignalInfo(id: course, name: "GPS course", unit: .degrees, category: .location, source: .gps),
        SignalInfo(id: accuracy, name: "GPS horizontal accuracy", unit: .meters, category: .location, source: .gps),
    ]
}

public enum AdapterSignals {
    /// The adapter's own reading of the OBD port supply (pin 16), via ATRV. Not an ECU value.
    public static let batteryVoltage: SignalID = "adapter_voltage"
    public static let infos: [SignalInfo] = [
        SignalInfo(id: batteryVoltage, name: "Adapter supply voltage", unit: .volts, category: .electrical, source: .adapter, range: 10...16),
    ]
}
