import Foundation

/// Manufacturer-specific sensors for one vehicle, loaded from JSON (see `profiles/`).
public struct VehicleProfile: Codable, Sendable, Equatable {
    public var format: Int
    public var id: String
    public var name: String
    public var notes: String?
    public var sensors: [ProfileSensor]

    public init(format: Int = 1, id: String, name: String, notes: String? = nil, sensors: [ProfileSensor]) {
        self.format = format
        self.id = id
        self.name = name
        self.notes = notes
        self.sensors = sensors
    }

    public static func decode(_ data: Data) throws -> VehicleProfile {
        let p = try JSONDecoder().decode(VehicleProfile.self, from: data)
        guard p.format == 1 else { throw ProfileError.unsupportedFormat(p.format) }
        for s in p.sensors { try s.validate() }
        return p
    }
}

public enum ProfileError: Error, Equatable {
    case unsupportedFormat(Int)
    case invalidSensor(String, String)
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
