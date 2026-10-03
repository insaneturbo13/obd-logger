import Foundation

extension PollPlan {
    /// A profile mode with its periods resolved to poll item keys.
    public struct Mode: Sendable, Equatable {
        public let id: String
        public let when: PollMode.Condition
        public let periods: [String: Double]
    }

    /// Resolves the profile's modes against the items on this car. Items the user set a
    /// period for keep it in every mode.
    static func resolveModes(_ profile: VehicleProfile?, items: [PollItem], sensorKeys: [String: String],
                             overrides: PollOverrides) -> [Mode] {
        let keys = Set(items.map(\.key))
        return (profile?.modes ?? []).map { m in
            var periods: [String: Double] = [:]
            for (pid, period) in m.standardPeriods ?? [:] {
                guard let p = UInt8(pid, radix: 16) else { continue }
                periods[PollItem(header: engineHeader, request: .mode01(p), period: period).key] = period
            }
            for (id, period) in m.sensorPeriods ?? [:] {
                if let key = sensorKeys[id] { periods[key] = period }
            }
            periods = periods.filter { keys.contains($0.key) && overrides.periods[$0.key] == nil }
            return Mode(id: m.id, when: m.when, periods: periods)
        }
    }
}

/// Decides which modes are active from the readings as they arrive.
public struct PollModeTracker: Sendable {
    public let modes: [PollPlan.Mode]
    public private(set) var active: Set<String> = []
    private var stoppedSince: Double?
    private var coolant: Double?
    /// How far below its threshold coolant must fall before a coolant mode ends (°C).
    static let coolantHysteresis = 2.0

    public init(modes: [PollPlan.Mode]) { self.modes = modes }

    /// Feeds new readings taken at `now` (seconds). Returns true if the active modes changed.
    public mutating func ingest(_ samples: [Sample], now: Double) -> Bool {
        for s in samples {
            switch s.signal {
            case "speed":
                if s.value > 0 { stoppedSince = nil } else if stoppedSince == nil { stoppedSince = now }
            case "coolant_temp":
                coolant = s.value
            default:
                break
            }
        }
        var next: Set<String> = []
        for m in modes where holds(m.when, now: now, wasActive: active.contains(m.id)) { next.insert(m.id) }
        guard next != active else { return false }
        active = next
        return true
    }

    private func holds(_ c: PollMode.Condition, now: Double, wasActive: Bool) -> Bool {
        if let wait = c.stationaryFor {
            guard let since = stoppedSince, now - since >= wait else { return false }
        }
        if let limit = c.coolantAtLeast {
            guard let coolant, coolant >= (wasActive ? limit - Self.coolantHysteresis : limit) else { return false }
        }
        return true
    }

    /// The period an item should use now, or nil to keep its normal one.
    public func period(for key: String) -> Double? {
        modes.filter { active.contains($0.id) }.compactMap { $0.periods[key] }.min()
    }
}
