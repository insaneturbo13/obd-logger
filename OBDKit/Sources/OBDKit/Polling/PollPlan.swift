import Foundation

public enum PollRequest: Hashable, Sendable {
    /// Service 01 PID. Packable: up to six share one request.
    case mode01(UInt8)
    /// A profile sensor (SSM A8 or service 22), one per request.
    case profile(id: String, command: String)
}

/// Something the scheduler asks for at a target period.
public struct PollItem: Hashable, Sendable {
    /// Stable key, e.g. "7E0:01:0C" or "7E1:A8000056". Used for settings and the capability map.
    public let key: String
    public let header: UInt16
    public let request: PollRequest
    public var period: Double

    public init(header: UInt16, request: PollRequest, period: Double) {
        self.header = header
        self.request = request
        self.period = period
        switch request {
        case .mode01(let pid): key = "\(hex3(header)):01:\(hex2(pid))"
        case .profile(_, let command): key = "\(hex3(header)):\(command)"
        }
    }
}

/// User adjustments, keyed by poll item key.
public struct PollOverrides: Codable, Sendable, Equatable {
    public var periods: [String: Double] = [:]
    /// Items switched off by the user.
    public var disabled: Set<String> = []
    /// Items off by default (e.g. "no-information") that the user switched on.
    public var enabled: Set<String> = []

    public init() {}
}

/// What to poll on this car: the standard PIDs the engine computer reports as supported,
/// plus the enabled sensors of the vehicle profile.
public struct PollPlan: Sendable {
    public var items: [PollItem]
    /// Items known but not polled (disabled by default or by the user).
    public var inactive: [PollItem]
    public var signals: [SignalID: SignalInfo]
    public var itemKeyForSignal: [SignalID: String]
    public var profileSensors: [String: ProfileSensor]

    public static let engineHeader: UInt16 = 0x7E0

    public static func build(supported: Set<UInt8>, profile: VehicleProfile?, overrides: PollOverrides = PollOverrides()) -> PollPlan {
        var items: [PollItem] = []
        var inactive: [PollItem] = []
        var signals: [SignalID: SignalInfo] = [:]
        var itemKeyForSignal: [SignalID: String] = [:]
        var sensors: [String: ProfileSensor] = [:]

        func place(_ item: PollItem, defaultOn: Bool) {
            var item = item
            if let p = overrides.periods[item.key], p > 0 { item.period = p }
            let on = overrides.disabled.contains(item.key) ? false : (defaultOn || overrides.enabled.contains(item.key))
            if on { items.append(item) } else { inactive.append(item) }
        }

        for pid in supported.sorted() where !StandardPIDs.isSupportBitmap(pid) {
            guard let def = StandardPIDs.all[pid] else { continue }
            let item = PollItem(header: engineHeader, request: .mode01(pid), period: def.period)
            for o in def.outputs {
                signals[o.info.id] = o.info
                itemKeyForSignal[o.info.id] = item.key
            }
            place(item, defaultOn: true)
        }
        for s in profile?.sensors ?? [] {
            guard let header = s.header, let command = s.request else { continue }
            let item = PollItem(header: header, request: .profile(id: s.id, command: command), period: s.period ?? 2)
            sensors[s.id] = s
            signals[s.signalID] = s.info
            itemKeyForSignal[s.signalID] = item.key
            place(item, defaultOn: s.enabled ?? true)
        }
        return PollPlan(items: items, inactive: inactive, signals: signals,
                        itemKeyForSignal: itemKeyForSignal, profileSensors: sensors)
    }
}
