import Foundation
import OBDKit
import SwiftUI

/// Everything a widget needs to show one signal, already converted to display units.
struct SignalReading {
    let id: SignalID
    let name: String
    let value: DisplayValue?
    /// Display-unit span for gauges.
    let span: ClosedRange<Double>?
    let age: TimeInterval?
    let stale: Bool
    let status: String?

    var text: String { value?.text ?? "–" }
    var unit: String { value?.unit ?? "" }

    /// Position of a display-unit number within the span, 0...1.
    func position(_ v: Double?) -> Double? {
        guard let v, let span, span.upperBound > span.lowerBound else { return nil }
        return min(1, max(0, (v - span.lowerBound) / (span.upperBound - span.lowerBound)))
    }

    var fraction: Double? { position(value?.value) }
}

/// Signal names, units and ranges from every source the app knows.
enum SignalRegistry {
    static let infos: [SignalID: SignalInfo] = {
        var all: [SignalID: SignalInfo] = [:]
        for i in StandardPIDs.signalInfos + DerivedSignals.infos + GPSSignals.infos + AdapterSignals.infos { all[i.id] = i }
        for p in BuiltInProfiles.all { for s in p.sensors { all[s.signalID] = s.info } }
        return all
    }()

    static func info(_ id: SignalID) -> SignalInfo? { infos[id] }
}

@MainActor
extension LoggerEngine {
    /// Seconds after which a value counts as stale: three times how often it actually
    /// arrives (or is meant to), and never less than 3 s.
    func staleAfter(_ id: SignalID) -> TimeInterval {
        if let key = plan?.itemKeyForSignal[id] {
            let achieved = stats.items[key]?.achievedPeriod
            let target = plan?.items.first { $0.key == key }?.period
            return max(3, 3 * (achieved ?? target ?? 1))
        }
        if id.rawValue.hasPrefix("gps_") { return 6 }
        return 5
    }

    func reading(_ id: SignalID, span: ClosedRange<Double>? = nil, decimals: Int? = nil) -> SignalReading {
        let info = SignalRegistry.info(id)
        let prefs = settings.prefs
        let r = live.latest[id]
        let value = r.flatMap { reading -> DisplayValue? in
            guard let unit = info?.unit else { return DisplayValue(value: reading.value, unit: "", decimals: decimals ?? 1) }
            return UnitConverter.display(reading.value, unit: unit, prefs: prefs, decimals: decimals)
        }
        var displaySpan = span
        if displaySpan == nil, let range = info?.range, let unit = info?.unit {
            let lo = UnitConverter.display(range.lowerBound, unit: unit, prefs: prefs).value
            let hi = UnitConverter.display(range.upperBound, unit: unit, prefs: prefs).value
            displaySpan = min(lo, hi)...max(lo, hi)
        }
        let age = r.map { live.now.timeIntervalSince($0.time) }
        let status = info?.status.flatMap { $0 == "verified" ? nil : $0 }
        return SignalReading(id: id, name: info?.name ?? id.rawValue, value: value, span: displaySpan,
                             age: age, stale: age.map { $0 > staleAfter(id) } ?? false, status: status)
    }
}

extension TimeInterval {
    var shortAge: String {
        if self < 60 { return "\(Int(self)) s" }
        if self < 3600 { return "\(Int(self / 60)) min" }
        return "\(Int(self / 3600)) h"
    }

    var clock: String {
        let s = Int(self)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
