import Foundation

public enum CSVExport {
    static func iso(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return f
    }

    static func quote(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// Every reading exactly as recorded: one row per value, stored units, true timestamps.
    public static func raw(_ trip: TripData, infos: [SignalID: SignalInfo], timeZone: TimeZone = .current) -> String {
        let f = iso(timeZone)
        let t0 = trip.start
        var rows: [(Date, SignalID, Double)] = []
        for (id, values) in trip.series { for v in values { rows.append((v.time, id, v.value)) } }
        rows.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out = "time,elapsed_s,signal,name,value,unit\n"
        out.reserveCapacity(rows.count * 48)
        for (t, id, v) in rows {
            let info = infos[id]
            out += "\(f.string(from: t)),\(String(format: "%.3f", t.timeIntervalSince(t0))),\(id.rawValue),"
            out += "\(quote(info?.name ?? id.rawValue)),\(TripFiles.format(v)),\(info?.unit.symbol ?? "")\n"
        }
        return out
    }

    /// One row per time step with a column per signal, in display units.
    ///
    /// A value is carried forward only while it's fresh: up to `carryFactor` times that
    /// signal's own typical interval in this trip (and at least `minCarry` seconds). After
    /// that the cell is left empty, so a stalled adapter shows up as a gap instead of
    /// looking like steady readings.
    public static func wide(_ trip: TripData, infos: [SignalID: SignalInfo], prefs: DisplayPreferences,
                            step: TimeInterval = 0.5, carryFactor: Double = 2.5, minCarry: TimeInterval = 1.5,
                            includeAge: Bool = false, timeZone: TimeZone = .current) -> String {
        let f = iso(timeZone)
        let ids = orderedSignals(trip, infos: infos)
        var header = ["time", "elapsed_s"]
        var columns: [(id: SignalID, values: [TimedValue], cap: TimeInterval, unit: BaseUnit?)] = []
        for id in ids {
            guard let values = trip.series[id], !values.isEmpty else { continue }
            let info = infos[id]
            let unitText = info.map { UnitConverter.display(0, unit: $0.unit, prefs: prefs).unit } ?? ""
            let name = info?.name ?? id.rawValue
            header.append(quote(unitText.isEmpty ? name : "\(name) (\(unitText))"))
            if includeAge { header.append(quote("\(name) age (s)")) }
            columns.append((id, values, Swift.max(minCarry, carryFactor * typicalInterval(values)), info?.unit))
        }
        var out = header.joined(separator: ",") + "\n"
        let start = trip.start, end = trip.end
        guard end > start else { return out }
        var cursor = [Int](repeating: 0, count: columns.count)
        var t = start
        while t <= end {
            var row = [f.string(from: t), String(format: "%.1f", t.timeIntervalSince(start))]
            for (ci, col) in columns.enumerated() {
                var i = cursor[ci]
                while i + 1 < col.values.count && col.values[i + 1].time <= t { i += 1 }
                cursor[ci] = i
                let v = col.values[i]
                let age = t.timeIntervalSince(v.time)
                if age >= 0 && age <= col.cap {
                    let d = col.unit.map { UnitConverter.display(v.value, unit: $0, prefs: prefs) }
                    // One more decimal than the dashboard shows, so unit conversion doesn't lose resolution.
                    row.append(d.map { DisplayValue.format($0.value, decimals: $0.decimals + 1) } ?? TripFiles.format(v.value))
                    if includeAge { row.append(String(format: "%.1f", age)) }
                } else {
                    row.append("")
                    if includeAge { row.append(age >= 0 ? String(format: "%.1f", age) : "") }
                }
            }
            out += row.joined(separator: ",") + "\n"
            t = t.addingTimeInterval(step)
        }
        return out
    }

    /// Median spacing between readings.
    static func typicalInterval(_ values: [TimedValue]) -> TimeInterval {
        guard values.count > 2 else { return 5 }
        var gaps: [TimeInterval] = []
        gaps.reserveCapacity(values.count)
        for i in 1..<values.count { gaps.append(values[i].time.timeIntervalSince(values[i - 1].time)) }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    static func orderedSignals(_ trip: TripData, infos: [SignalID: SignalInfo]) -> [SignalID] {
        let order = SignalCategory.allCases
        return trip.series.keys.sorted { a, b in
            let ca = infos[a].map { order.firstIndex(of: $0.category)! } ?? order.count
            let cb = infos[b].map { order.firstIndex(of: $0.category)! } ?? order.count
            return ca != cb ? ca < cb : a < b
        }
    }
}

/// InfluxDB line protocol, one line per reading, stored units, millisecond timestamps.
public enum InfluxLineProtocol {
    static func escapeTag(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "=", with: "\\=").replacingOccurrences(of: " ", with: "\\ ")
    }

    public static func lines(_ trip: TripData, measurement: String = "trip", tags: [String: String]) -> [String] {
        let tagText = tags.keys.sorted().map { "\(escapeTag($0))=\(escapeTag(tags[$0]!))" }.joined(separator: ",")
        let prefix = escapeTag(measurement) + (tagText.isEmpty ? "" : "," + tagText)
        var out: [String] = []
        for id in trip.series.keys.sorted() {
            for v in trip.series[id]! where v.value.isFinite {
                out.append("\(prefix) \(escapeTag(id.rawValue))=\(TripFiles.format(v.value)) \(Int64((v.time.timeIntervalSince1970 * 1000).rounded()))")
            }
        }
        return out
    }
}
