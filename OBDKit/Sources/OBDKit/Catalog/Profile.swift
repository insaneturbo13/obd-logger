import Foundation

/// Manufacturer-specific sensors for one vehicle, loaded from JSON (see `profiles/`).
public struct VehicleProfile: Codable, Sendable, Equatable {
    public var format: Int
    public var id: String
    public var name: String
    public var notes: String?
    /// Poll periods (seconds) for standard service 01 PIDs on this car, keyed by PID as two hex
    /// digits ("05"). Replaces the generic default; the user's own setting still wins.
    public var standardPeriods: [String: Double]?
    /// Periods that apply only while the car is in some state (stopped, hot, ...).
    public var modes: [PollMode]?
    public var sensors: [ProfileSensor]

    public init(format: Int = 1, id: String, name: String, notes: String? = nil,
                standardPeriods: [String: Double]? = nil, modes: [PollMode]? = nil, sensors: [ProfileSensor]) {
        self.format = format
        self.id = id
        self.name = name
        self.notes = notes
        self.standardPeriods = standardPeriods
        self.modes = modes
        self.sensors = sensors
    }

    public static func decode(_ data: Data) throws -> VehicleProfile {
        let p = try JSONDecoder().decode(VehicleProfile.self, from: data)
        guard p.format == 1 else { throw ProfileError.unsupportedFormat(p.format) }
        for s in p.sensors { try s.validate() }
        try validatePeriods(p.standardPeriods ?? [:], context: "standardPeriods")
        for m in p.modes ?? [] {
            guard m.when.stationaryFor != nil || m.when.coolantAtLeast != nil else {
                throw ProfileError.invalidMode(m.id, "needs a condition")
            }
            try validatePeriods(m.standardPeriods ?? [:], context: m.id)
            for (id, period) in m.sensorPeriods ?? [:] {
                guard p.sensors.contains(where: { $0.id == id }) else { throw ProfileError.invalidMode(m.id, "unknown sensor \(id)") }
                guard period > 0 else { throw ProfileError.invalidMode(m.id, "period for \(id) must be positive") }
            }
        }
        return p
    }

    private static func validatePeriods(_ periods: [String: Double], context: String) throws {
        for (pid, period) in periods {
            guard pid.count == 2, UInt8(pid, radix: 16) != nil, period > 0 else {
                throw ProfileError.invalidStandardPeriod("\(context): \(pid)")
            }
        }
    }

    /// This car's period for a standard PID, if the profile sets one.
    public func standardPeriod(_ pid: UInt8) -> Double? {
        standardPeriods?.first { UInt8($0.key, radix: 16) == pid }?.value
    }
}

public enum ProfileError: Error, Equatable {
    case unsupportedFormat(Int)
    case invalidSensor(String, String)
    case invalidStandardPeriod(String)
    case invalidMode(String, String)
}

/// Poll periods for a car state. While the condition holds, the listed items use these
/// periods instead of their normal ones; if several modes are active, the shortest wins.
public struct PollMode: Codable, Sendable, Equatable {
    public struct Condition: Codable, Sendable, Equatable {
        /// Road speed has read 0 for this many seconds. Ends as soon as it reads above 0.
        public var stationaryFor: Double?
        /// Coolant at or above this temperature (°C). Ends 2 °C below it.
        public var coolantAtLeast: Double?

        public init(stationaryFor: Double? = nil, coolantAtLeast: Double? = nil) {
            self.stationaryFor = stationaryFor
            self.coolantAtLeast = coolantAtLeast
        }
    }

    public var id: String
    public var when: Condition
    /// Standard PID (two hex digits) -> period in seconds.
    public var standardPeriods: [String: Double]?
    /// Profile sensor id -> period in seconds.
    public var sensorPeriods: [String: Double]?

    public init(id: String, when: Condition, standardPeriods: [String: Double]? = nil, sensorPeriods: [String: Double]? = nil) {
        self.id = id
        self.when = when
        self.standardPeriods = standardPeriods
        self.sensorPeriods = sensorPeriods
    }
}

/// One manufacturer-specific value: which module to ask, how to ask, and how to scale the reply.
public struct ProfileSensor: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Request header (CAN ID) as hex, e.g. "7E1".
    public var module: String
    /// Subaru Select Monitor memory address (service A8), 6 hex digits.
    public var ssm: String?
    /// Read-by-identifier (service 22), 4 hex digits.
    public var did: String?
    /// Number of data bytes to decode (default 1).
    public var bytes: Int?
    public var signed: Bool?
    public var scale: Double?
    public var offset: Double?
    public var unit: BaseUnit
    public var category: SignalCategory?
    /// Default poll period in seconds.
    public var period: Double?
    /// "verified" | "candidate" | "assumed-scale" | "raw" | "no-information"
    public var status: String
    /// false = off unless the user turns it on (e.g. answers but carries no information).
    public var enabled: Bool?
    public var range: [Double]?
    public var evidence: String?

    public var header: UInt16? { UInt16(module, radix: 16) }

    public var request: String? {
        if let ssm, let a = UInt32(ssm, radix: 16) { return "A800" + hex6(a) }
        if let did, did.count == 4, Hex.isHex(did.uppercased()) { return "22" + did.uppercased() }
        return nil
    }

    public var signalID: SignalID { SignalID(id) }

    public var info: SignalInfo {
        let r: ClosedRange<Double>? = (range?.count == 2 && range![0] < range![1]) ? range![0]...range![1] : nil
        return SignalInfo(id: signalID, name: name, unit: unit, category: category ?? .drivetrain,
                          source: .profile, range: r, status: status)
    }

    func validate() throws {
        guard header != nil, module.count == 3 else { throw ProfileError.invalidSensor(id, "module must be a 3-digit CAN ID") }
        guard let request else { throw ProfileError.invalidSensor(id, "needs ssm (6 hex digits) or did (4 hex digits)") }
        do { try ReadOnlyGuard.check(request) } catch { throw ProfileError.invalidSensor(id, "\(error)") }
        if let ssm, ssm.count != 6 { throw ProfileError.invalidSensor(id, "ssm address must be 6 hex digits") }
        if let b = bytes, !(1...4).contains(b) { throw ProfileError.invalidSensor(id, "bytes must be 1-4") }
    }

    /// Scales the data bytes of a positive reply (after the service byte, and after the
    /// identifier for service 22).
    public func decode(_ data: [UInt8]) -> Double? {
        let n = bytes ?? 1
        guard data.count >= n else { return nil }
        var raw: Int64 = 0
        for b in data.prefix(n) { raw = raw << 8 | Int64(b) }
        if signed == true {
            let bits = Int64(n * 8)
            if raw >= (1 << (bits - 1)) { raw -= (1 << bits) }
        }
        return Double(raw) * (scale ?? 1) + (offset ?? 0)
    }

    /// Payload bytes that carry the value in a positive reply.
    public func valueBytes(fromPositive payload: [UInt8]) -> [UInt8] {
        did != nil ? Array(payload.dropFirst(3)) : Array(payload.dropFirst(1))
    }
}
