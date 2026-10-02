import Foundation

/// What this car has shown about each poll item, kept across trips so dead sensors aren't
/// re-requested every drive.
public struct CapabilityMap: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Never asked on this car.
        case unknown
        /// Answers.
        case active
        /// Asked several times with no answer at all. Retried once per connection.
        case silent
        /// The module said it doesn't support the request (negative response). Not asked again
        /// unless the user re-probes.
        case unsupported
    }

    public struct Record: Codable, Sendable, Equatable {
        public var state: State = .unknown
        public var answers = 0
        public var misses = 0
        public var consecutiveMisses = 0
        public var nrc: UInt8?
        public var lastAnswer: Date?
        public var updated: Date?
    }

    /// Identifies the car by what its modules report as supported (not the VIN).
    public var fingerprint: String
    public var records: [String: Record] = [:]

    public init(fingerprint: String) { self.fingerprint = fingerprint }

    public func state(_ key: String) -> State { records[key]?.state ?? .unknown }

    public mutating func recordAnswer(_ key: String, at time: Date) {
        var r = records[key] ?? Record()
        r.state = .active
        r.answers += 1
        r.consecutiveMisses = 0
        r.nrc = nil
        r.lastAnswer = time
        r.updated = time
        records[key] = r
    }

    /// Returns the backoff (seconds) the scheduler should apply, if any.
    @discardableResult
    public mutating func recordMiss(_ key: String, status: ReplyStatus, nrc: UInt8?, at time: Date) -> Double? {
        var r = records[key] ?? Record()
        r.misses += 1
        r.consecutiveMisses += 1
        r.updated = time
        defer { records[key] = r }
        switch status {
        case .notSupported, .negative:
            r.state = .unsupported
            r.nrc = nrc
            return .infinity
        case .conditional, .pending:
            r.nrc = nrc
            return 30
        default:
            break
        }
        switch r.state {
        case .active:
            // A sensor that used to answer: brief hiccups are normal, so only back off after a run.
            guard r.consecutiveMisses >= 3 else { return nil }
            return min(600, 15 * pow(2, Double(r.consecutiveMisses - 3)))
        case .unknown, .silent:
            guard r.consecutiveMisses >= 2 else { return nil }
            r.state = .silent
            return 600
        case .unsupported:
            return .infinity
        }
    }

    /// Lets the user try a sensor again.
    public mutating func reset(_ key: String) { records[key] = nil }

    /// Builds the fingerprint from the supported-PID bitmaps of each responding module.
    public static func fingerprint(bitmaps: [UInt16: [UInt8: [UInt8]]]) -> String {
        bitmaps.keys.sorted().map { id in
            let parts = bitmaps[id]!.keys.sorted().map { base in "\(hex2(base))=\(Hex.string(bitmaps[id]![base]!))" }
            return "\(hex3(id)):" + parts.joined(separator: ",")
        }.joined(separator: ";")
    }
}
