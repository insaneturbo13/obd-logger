import Foundation

/// Reads trip CSVs made elsewhere into ordinary trip folders, so a trip recorded on another
/// device (the iPad's exports in a shared folder) or by another app can be browsed here.
///
/// Formats, told apart by their header:
/// - **Raw export** (`time,elapsed_s,signal,name,value,unit`): every reading with its real
///   time in stored units. The import is exact.
/// - **Table export** (`time,elapsed_s,<name (unit)>…`): for a trip exported without its raw
///   file. Display units are converted back to stored units.
/// - **Car Scanner CSV** (`time,<name (unit)>…`): the time column has the time of day only;
///   the date comes from the file name (`2026-10-01 15-16-54.csv`, as Car Scanner names its
///   recordings) and the clock is read in the importing device's time zone.
///
/// Table-style files repeat a value on every row until a new one arrives (Car Scanner
/// without any limit), so a repeat is not a reading. The import keeps every change plus one
/// repeat per second while a value holds: charts and trip totals come out right, but a stall
/// the source papered over stays invisible, and the trip's notes say so.
public enum TripImport {
    public enum Format: String, Codable, Sendable, Equatable {
        case raw = "OBD Logger raw export"
        case table = "OBD Logger table export"
        case carScanner = "Car Scanner export"
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case unrecognized
        case noDateInFileName(String)
        case noReadings
        case exists(String)

        public var description: String {
            switch self {
            case .unrecognized:
                return "Not a trip export this app can read."
            case .noDateInFileName(let name):
                return "\(name): Car Scanner files carry the date only in their name (like 2026-10-01 15-16-54.csv), and this name has none."
            case .noReadings:
                return "The file has no readings."
            case .exists(let id):
                return "Trip \(id) is already on this device."
            }
        }
    }

    public struct Imported: Sendable {
        public var trip: TripData
        public var format: Format
        /// Source columns left out: Car Scanner's running totals, averages and prices, and
        /// duplicates of a column already read.
        public var skippedColumns: [String]
    }

    /// While a table-style file holds a value, keep one repeat this often (seconds).
    public static let keepAlive: TimeInterval = 1

    // MARK: file names

    /// The trip a file belongs to, from its name: "2026-10-05_06-49-31-raw.csv",
    /// "2026-10-05_06-49-31.csv", "2026-10-01 15-16-54.csv" (Car Scanner) and
    /// "2026-09-03 14-46-15 2.csv" (a sync service's duplicate) all give "YYYY-MM-DD_HH-mm-ss".
    /// nil when the name doesn't start with a date and time.
    public static func tripID(fromFileName name: String) -> String? {
        guard let p = nameParts(name), let t = p.time else { return nil }
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", p.year, p.month, p.day, t.hour, t.minute, t.second)
    }

    /// This app's raw export of a trip ("<trip>-raw.csv"); preferred over the table export.
    public static func isRawExport(fileName: String) -> Bool {
        fileName.lowercased().hasSuffix("-raw.csv")
    }

    struct NameParts {
        var year: Int, month: Int, day: Int
        var time: (hour: Int, minute: Int, second: Int)?
    }

    static func nameParts(_ name: String) -> NameParts? {
        let u = Array(name.utf8)
        guard u.count >= 10, let y = digits(u, 0, 4), u[4] == 0x2D, let mo = digits(u, 5, 2), u[7] == 0x2D,
              let d = digits(u, 8, 2), (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var p = NameParts(year: y, month: mo, day: d)
        if u.count >= 19, u[10] == 0x20 || u[10] == 0x5F, let h = digits(u, 11, 2), u[13] == 0x2D,
           let mi = digits(u, 14, 2), u[16] == 0x2D, let s = digits(u, 17, 2), h < 24, mi < 60, s < 61 {
            p.time = (h, mi, s)
        }
        return p
    }

    // MARK: format

    /// The format a header row announces, or nil if it isn't a trip export.
    public static func format(ofHeader fields: [String]) -> Format? {
        let f = fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 2, f[0].lowercased() == "time" else { return nil }
        if f.count >= 6, f[1] == "elapsed_s", f[2] == "signal", f[3] == "name", f[4] == "value", f[5] == "unit" { return .raw }
        if f[1] == "elapsed_s" { return .table }
        return .carScanner
    }

    // MARK: parse

    /// Reads one exported file. `timeZone` is used only where the file has local clock times
    /// without an offset (Car Scanner). `appVersion` is recorded as the importing version.
    public static func parse(_ data: Data, fileName: String, timeZone: TimeZone = .current,
                             appVersion: String, importedAt: Date = Date()) throws -> Imported {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = CSVText.lines(text)
        guard let headerLine = lines.first else { throw ImportError.unrecognized }
        let header = CSVText.fields(headerLine).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let format = format(ofHeader: header) else { throw ImportError.unrecognized }
        let rows = lines.dropFirst()

        var b = Builder()
        var skipped: [String] = []
        switch format {
        case .raw:
            readRaw(rows, into: &b)
        case .table:
            skipped = readTable(header, rows, zone: timeZone, into: &b)
        case .carScanner:
            skipped = try readCarScanner(header, rows, fileName: fileName, zone: timeZone, into: &b)
        }
        guard b.count > 0 else { throw ImportError.noReadings }

        var series: [SignalID: [TimedValue]] = [:]
        for (id, values) in b.series where !values.isEmpty {
            series[id] = values.sorted { $0.time < $1.time }
        }
        let start = series.values.compactMap { $0.first?.time }.min()!
        let end = series.values.compactMap { $0.last?.time }.max()!
        let id = tripID(fromFileName: fileName) ?? TripMeta.id(for: start, timeZone: timeZone)
        let signals = series.keys.compactMap { b.infos[$0] }.sorted { $0.id < $1.id }

        var meta = TripMeta(id: id, startedAt: start, appVersion: appVersion, signals: signals)
        meta.endedAt = end
        meta.segments = [TripMeta.Segment(start: start, end: end)]
        meta.importedFrom = fileName
        meta.importedAt = importedAt
        meta.notes = note(for: format, fileName: fileName)
        var trip = TripData(meta: meta, series: series,
                            events: [TripEvent(time: start, kind: "imported", detail: "\(format.rawValue) \(fileName)")])
        trip.meta.summary = trip.summarize()
        return Imported(trip: trip, format: format, skippedColumns: skipped)
    }

    static func note(for format: Format, fileName: String) -> String {
        switch format {
        case .raw:
            return "Imported from \(fileName)."
        case .table:
            return "Imported from the table export \(fileName) (no raw export was there): values repeated while fresh were reduced to their changes plus one reading per second."
        case .carScanner:
            return "Imported from the Car Scanner export \(fileName). Car Scanner repeats each value until a new one arrives, so the import kept the changes plus one reading per second; a stalled adapter can't be told from a steady value."
        }
    }

    // MARK: write

    /// Saves an imported trip as an ordinary trip folder under `root` (readable with
    /// `TripData.load`). Assembled elsewhere and moved into place, so a half-written trip
    /// never shows up. Throws `ImportError.exists` if the trip is already there.
    @discardableResult
    public static func write(_ trip: TripData, to root: URL) throws -> URL {
        let fm = FileManager.default
        let final = root.appendingPathComponent(trip.meta.id, isDirectory: true)
        if fm.fileExists(atPath: final.path) { throw ImportError.exists(trip.meta.id) }
        let stage = fm.temporaryDirectory.appendingPathComponent("trip-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        var rows: [(ms: Int64, id: SignalID, value: Double)] = []
        rows.reserveCapacity(trip.series.values.reduce(0) { $0 + $1.count })
        for (id, values) in trip.series {
            for v in values { rows.append((Int64((v.time.timeIntervalSince1970 * 1000).rounded()), id, v.value)) }
        }
        rows.sort { $0.ms != $1.ms ? $0.ms < $1.ms : $0.id < $1.id }
        var samples = TripFiles.samplesHeader
        samples.reserveCapacity(rows.count * 30)
        for r in rows { samples += "\(r.ms),\(r.id.rawValue),\(TripFiles.format(r.value))\n" }
        try Data(samples.utf8).write(to: stage.appendingPathComponent(TripFiles.samples))

        var events = TripFiles.eventsHeader
        for e in trip.events {
            let detail = e.detail.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
            events += "\(Int64((e.time.timeIntervalSince1970 * 1000).rounded())),\(e.kind),\"\(detail)\"\n"
        }
        try Data(events.utf8).write(to: stage.appendingPathComponent(TripFiles.events))
        try TripFiles.writeMeta(trip.meta, to: stage)

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.moveItem(at: stage, to: final)
        return final
    }

    // MARK: readers

    struct Builder {
        var series: [SignalID: [TimedValue]] = [:]
        var infos: [SignalID: SignalInfo] = [:]
        var count = 0

        mutating func add(_ id: SignalID, _ t: Double, _ v: Double) {
            guard v.isFinite, t.isFinite else { return }
            series[id, default: []].append(TimedValue(Date(timeIntervalSince1970: t), v))
            count += 1
        }
    }

    /// Keeps a value when it changed, or when it has held for `keepAlive` seconds.
    struct Thinner {
        var last: Double?
        var lastTime = -Double.infinity

        mutating func keep(_ v: Double, at t: Double) -> Bool {
            guard v != last || t - lastTime >= TripImport.keepAlive else { return false }
            last = v
            lastTime = t
            return true
        }
    }

    struct Column {
        let index: Int
        let id: SignalID
        let convert: @Sendable (Double) -> Double
    }

    static func readRaw(_ rows: ArraySlice<Substring>, into b: inout Builder) {
        var ids: [Substring: SignalID] = [:]
        var zones = ZoneCache()
        for line in rows {
            let f = CSVText.fields(line)
            guard f.count >= 6, let t = epochSeconds(f[0], localZone: nil, zones: &zones), let v = Double(f[4]) else { continue }
            let id: SignalID
            if let known = ids[f[2]] {
                id = known
            } else {
                id = SignalID(String(f[2]))
                ids[f[2]] = id
                if b.infos[id] == nil {
                    b.infos[id] = SignalCatalog.infos[id] ?? SignalInfo(
                        id: id, name: String(f[3]), unit: ImportUnit.base(forSymbol: String(f[5])),
                        category: .status, source: .imported)
                }
            }
            b.add(id, t, v)
        }
    }

    static func readTable(_ header: [String], _ rows: ArraySlice<Substring>, zone: TimeZone, into b: inout Builder) -> [String] {
        var columns: [Column] = []
        var skipped: [String] = []
        var used = Set<SignalID>()
        for i in header.indices.dropFirst(2) where !header[i].isEmpty {
            let (name, unitText) = splitHeader(header[i])
            // Optional "<name> age (s)" columns describe freshness, not the car.
            if unitText == "s", name.lowercased().hasSuffix(" age") { continue }
            if let id = SignalCatalog.byName[name.lowercased()], let info = SignalCatalog.infos[id],
               let convert = converter(to: info, from: unitText) {
                guard used.insert(id).inserted else { skipped.append(header[i]); continue }
                b.infos[id] = info
                columns.append(Column(index: i, id: id, convert: convert))
            } else if let column = extraColumn(index: i, name: name, unitText: unitText, prefix: "x_", used: &used, into: &b) {
                columns.append(column)
            } else {
                skipped.append(header[i])
            }
        }
        var thinners = [Thinner](repeating: Thinner(), count: columns.count)
        var zones = ZoneCache()
        for line in rows {
            let f = CSVText.fields(line)
            guard let first = f.first, let t = epochSeconds(first, localZone: zone, zones: &zones) else { continue }
            read(f, at: t, columns, &thinners, into: &b)
        }
        return skipped
    }

    static func readCarScanner(_ header: [String], _ rows: ArraySlice<Substring>, fileName: String,
                               zone: TimeZone, into b: inout Builder) throws -> [String] {
        let split = header.map(splitHeader)
        let keys = split.map { $0.name.lowercased() }
        let hasRPM = keys.contains("engine rpm")
        // Car Scanner names both wide-range O2 ratio PIDs the same. With two columns the first
        // is PID 24 (the voltage type) and the second PID 34 (the current type); a lone one
        // belongs to whichever partner value (voltage or current) the file has.
        let ratioColumns = keys.indices.filter { keys[$0] == "oxygen sensor 1 wide range equivalence ratio" }
        let loneRatioIsCurrentType = keys.contains("oxygen sensor 1 wide range current (ma)")
            && !keys.contains("oxygen sensor 1 wide range voltage")

        var columns: [Column] = []
        var skipped: [String] = []
        var used = Set<SignalID>()
        for i in header.indices.dropFirst() where !header[i].isEmpty {
            let (name, unitText) = split[i]
            let key = keys[i]
            var target: SignalID?
            var scale = 1.0
            if key == "oxygen sensor 1 wide range equivalence ratio" {
                if ratioColumns.count >= 2 {
                    target = i == ratioColumns[0] ? "o2_b1s1_eq_ratio_v" : i == ratioColumns[1] ? "o2_b1s1_eq_ratio" : nil
                } else {
                    target = loneRatioIsCurrentType ? "o2_b1s1_eq_ratio" : "o2_b1s1_eq_ratio_v"
                }
            } else if key == "engine rpm x1000" {
                // A rounded copy of engine speed; only read when the full value is missing.
                guard !hasRPM else { skipped.append(header[i]); continue }
                target = "rpm"
                scale = 1000
            } else if let mapped = carScannerSignals[key] {
                target = mapped
            } else if isCarScannerBookkeeping(key, unit: unitText) {
                skipped.append(header[i])
                continue
            }
            if let target, let info = SignalCatalog.infos[target],
               let convert = converter(to: info, from: scale == 1 ? unitText : ""), !used.contains(target) {
                used.insert(target)
                b.infos[target] = info
                let s = scale
                let scaled: @Sendable (Double) -> Double = s == 1 ? convert : { @Sendable v in convert(v * s) }
                columns.append(Column(index: i, id: target, convert: scaled))
            } else if let column = extraColumn(index: i, name: name, unitText: unitText, prefix: "cs_", used: &used, into: &b) {
                columns.append(column)
            } else {
                skipped.append(header[i])
            }
        }

        let parts = nameParts(fileName)
        let dayStart = parts.map { Double(daysFromCivil($0.year, $0.month, $0.day)) * 86400 }
        // Starting from the name's clock time lets a recording that began just before midnight roll over.
        var previous: Double? = parts?.time.map { Double($0.hour * 3600 + $0.minute * 60 + $0.second) }
        var dayOffset = 0.0
        var thinners = [Thinner](repeating: Thinner(), count: columns.count)
        var zones = ZoneCache()
        for line in rows {
            let f = CSVText.fields(line)
            guard let field = f.first else { continue }
            let t: Double
            if field.utf8.count >= 19, let full = epochSeconds(field, localZone: zone, zones: &zones) {
                t = full
            } else if let sod = secondsOfDay(field) {
                guard let dayStart else { throw ImportError.noDateInFileName(fileName) }
                if let p = previous, sod < p - 3600 { dayOffset += 86400 }
                previous = sod
                t = zones.utc(fromLocal: dayStart + dayOffset + sod, zone: zone)
            } else {
                continue
            }
            read(f, at: t, columns, &thinners, into: &b)
        }
        return skipped
    }

    static func read(_ f: [Substring], at t: Double, _ columns: [Column], _ thinners: inout [Thinner], into b: inout Builder) {
        for (k, c) in columns.enumerated() where c.index < f.count {
            let cell = f[c.index]
            guard !cell.isEmpty, let raw = Double(cell) else { continue }
            let v = c.convert(raw)
            if thinners[k].keep(v, at: t) { b.add(c.id, t, v) }
        }
    }

    /// A column with no counterpart in the catalog, kept under its own (prefixed) name.
    static func extraColumn(index: Int, name: String, unitText: String, prefix: String,
                            used: inout Set<SignalID>, into b: inout Builder) -> Column? {
        let slug = slug(name)
        guard !slug.isEmpty else { return nil }
        let id = SignalID(prefix + slug)
        guard used.insert(id).inserted else { return nil }
        let unit = ImportUnit.parse(unitText)
        let shownName = unit == nil && !unitText.isEmpty ? "\(name) (\(unitText))" : name
        b.infos[id] = SignalInfo(id: id, name: shownName, unit: unit?.base ?? .raw, category: .status, source: .imported)
        let same: @Sendable (Double) -> Double = { @Sendable v in v }
        return Column(index: index, id: id, convert: unit?.toBase ?? same)
    }

    /// How to turn a column written in `unitText` into this signal's stored unit; nil if it can't be.
    static func converter(to info: SignalInfo, from unitText: String) -> (@Sendable (Double) -> Double)? {
        let same: @Sendable (Double) -> Double = { @Sendable v in v }
        if info.unit == .raw { return same }
        if let u = ImportUnit.parse(unitText) { return u.base == info.unit ? u.toBase : nil }
        guard unitText.isEmpty || unitText == info.unit.symbol else { return nil }
        // Car Scanner writes equivalence ratios as air-fuel ratios (14.7 at stoichiometry).
        if info.unit == .lambda {
            return { @Sendable v in v > 3 ? ImportUnit.tidy(v / UnitConverter.stoichiometricAFR) : v }
        }
        return same
    }

    /// "Engine RPM (rpm)" -> ("Engine RPM", "rpm"); "Fuel level input (%) (%)" -> ("Fuel level input (%)", "%");
    /// "Latitude" -> ("Latitude", ""); "# warm-ups since codes cleared ()" -> ("# warm-ups since codes cleared", "").
    static func splitHeader(_ header: String) -> (name: String, unit: String) {
        let h = header.trimmingCharacters(in: .whitespaces)
        if SignalCatalog.byName[h.lowercased()] != nil { return (h, "") }
        guard h.hasSuffix(")"), let open = h.range(of: " (", options: .backwards) else { return (h, "") }
        return (String(h[..<open.lowerBound]), String(h[open.upperBound..<h.index(before: h.endIndex)]))
    }

    static func slug(_ s: String) -> String {
        var out = ""
        var underscore = false
        for ch in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII {
                out.unicodeScalars.append(ch)
                underscore = false
            } else if !underscore && !out.isEmpty {
                out += "_"
                underscore = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    // MARK: Car Scanner columns

    /// Car Scanner column names (lowercased, without the unit) and the signal each one is.
    /// The Subaru entries read the same module addresses as this app's profile.
    static let carScannerSignals: [String: SignalID] = [
        "engine rpm": "rpm",
        "vehicle speed": "speed",
        "engine coolant temperature": "coolant_temp",
        "intake air temperature": "intake_air_temp",
        "ambient air temperature": "ambient_air_temp",
        "catalyst temperature bank 1 sensor 1": "cat_temp_b1s1",
        "engine oil temperature var.2": "oil_temp",
        "engine oil temperature": "oil_temp_std",
        "at/cvt temperature v.2": "cvt_fluid_temp",
        "calculated engine load value": "engine_load",
        "absolute load value": "absolute_load",
        "intake manifold absolute pressure": "map",
        "barometric pressure": "baro",
        "maf air flow rate": "maf",
        "timing advance": "timing_advance",
        "throttle position": "throttle",
        "relative throttle position": "relative_throttle",
        "absolute throttle position b": "throttle_b",
        "commanded throttle actuator": "commanded_throttle",
        "absolute pedal position d": "pedal_d",
        "absolute pedal position e": "pedal_e",
        "relative accelerator pedal position": "relative_pedal",
        "short term fuel % trim - bank 1": "stft_b1",
        "long term fuel % trim - bank 1": "ltft_b1",
        "fuel/air commanded equivalence ratio": "commanded_eq_ratio",
        "oxygen sensor 1 wide range current (ma)": "o2_b1s1_wr_current",
        "oxygen sensor 1 wide range voltage": "o2_b1s1_wr_voltage",
        "oxygen sensor 2 bank 1 voltage": "o2_b1s2_voltage",
        "oxygen sensor 2 bank 1 short term fuel trim": "o2_b1s2_trim",
        "commanded egr duty": "egr_commanded",
        "egr error": "egr_error",
        "commanded evaporative purge": "evap_purge",
        "evap. system vapor pressure": "evap_pressure",
        "fuel level input (%)": "fuel_level",
        "control module voltage": "module_voltage",
        "obd module voltage": "adapter_voltage",
        "distance traveled with mil on": "distance_mil_on",
        "distance traveled since codes cleared": "distance_since_clear",
        "# warm-ups since codes cleared": "warmups_since_clear",
        "turbine speed": "turbine_speed",
        "lock-up duty ratio": "lockup_duty",
        "transfer duty ratio": "transfer_duty",
        "front wheel speed": "front_wheel_speed_tcm",
        "rear wheel speed": "rear_wheel_speed_tcm",
        "abs/vdc front wheel mean speed": "front_axle_speed_vdc",
        "abs/vdc rear wheel mean speed": "rear_axle_speed_vdc",
        "front:rear wheel rotation ratio": "front_rear_rotation_ratio",
        "atf deterioration": "atf_deterioration",
        "calculated instant fuel rate": "fuel_rate",
        "calculated instant fuel consumption": "fuel_economy",
        "fuel used": "fuel_used",
        "distance travelled": "distance",
        "calculated boost": "boost",
        "vehicle acceleration": "acceleration",
        "power from maf": "power_estimate",
        "latitude": "gps_lat",
        "longitude": "gps_lon",
        "longtitude": "gps_lon",
        "speed (gps)": "gps_speed",
        "altitude (gps)": "gps_alt",
    ]

    /// Car Scanner's own bookkeeping (totals per day/week, averages, prices, range estimates),
    /// computed from the readings and the user's fuel price, not read from the car.
    static func isCarScannerBookkeeping(_ key: String, unit: String) -> Bool {
        if unit == "$" { return true }
        let prefixes = ["average ", "fuel used price", "fuel economizer", "instant engine power", "distance to empty",
                        "free space in fuel tank", "fuel level input (v)"]
        if prefixes.contains(where: { key.hasPrefix($0) }) { return true }
        return key.hasSuffix("(today)") || key.hasSuffix("(week)") || key.hasSuffix("(total)")
    }

    // MARK: time

    /// Seconds since 1970 for "2026-10-05T06:49:31.841-06:00" ("Z", "+0000" and no fraction
    /// too; a space may replace the "T"). Without an offset the clock is read in `localZone`,
    /// or rejected when there is none.
    static func epochSeconds(_ s: Substring, localZone: TimeZone?, zones: inout ZoneCache) -> Double? {
        let u = Array(s.utf8)
        guard u.count >= 19, let y = digits(u, 0, 4), u[4] == 0x2D, let mo = digits(u, 5, 2), u[7] == 0x2D,
              let d = digits(u, 8, 2), u[10] == 0x54 || u[10] == 0x20, let h = digits(u, 11, 2), u[13] == 0x3A,
              let mi = digits(u, 14, 2), u[16] == 0x3A, let sec = digits(u, 17, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        var i = 19
        let frac = fraction(u, &i)
        let local = Double(daysFromCivil(y, mo, d)) * 86400 + Double(h * 3600 + mi * 60 + sec) + frac
        guard i < u.count else { return localZone.map { zones.utc(fromLocal: local, zone: $0) } }
        if u[i] == 0x5A { return local }
        guard u[i] == 0x2B || u[i] == 0x2D, let oh = digits(u, i + 1, 2) else { return nil }
        var om = 0
        if let m = digits(u, i + 3, 2) { om = m } else if i + 3 < u.count, u[i + 3] == 0x3A, let m = digits(u, i + 4, 2) { om = m }
        let offset = Double(oh * 3600 + om * 60)
        return u[i] == 0x2B ? local - offset : local + offset
    }

    /// Seconds since midnight for "15:16:54.645" or "9:05:01".
    static func secondsOfDay(_ s: Substring) -> Double? {
        let u = Array(s.utf8)
        var i = 0
        var h = 0
        while i < u.count, i < 2, (0x30...0x39).contains(u[i]) {
            h = h * 10 + Int(u[i] - 0x30)
            i += 1
        }
        guard i > 0, i < u.count, u[i] == 0x3A, let mi = digits(u, i + 1, 2), i + 3 < u.count, u[i + 3] == 0x3A,
              let sec = digits(u, i + 4, 2), h < 24, mi < 60, sec < 61 else { return nil }
        i += 6
        let frac = fraction(u, &i)
        return Double(h * 3600 + mi * 60 + sec) + frac
    }

    static func fraction(_ u: [UInt8], _ i: inout Int) -> Double {
        guard i < u.count, u[i] == 0x2E || u[i] == 0x2C else { return 0 }
        i += 1
        var value = 0.0
        var scale = 1.0
        while i < u.count, (0x30...0x39).contains(u[i]) {
            if scale < 1e9 {
                value = value * 10 + Double(u[i] - 0x30)
                scale *= 10
            }
            i += 1
        }
        return value / scale
    }

    static func digits(_ u: [UInt8], _ at: Int, _ count: Int) -> Int? {
        guard at >= 0, at + count <= u.count else { return nil }
        var v = 0
        for k in at..<(at + count) {
            guard (0x30...0x39).contains(u[k]) else { return nil }
            v = v * 10 + Int(u[k] - 0x30)
        }
        return v
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Turns local clock times into UTC, asking the time zone once per half hour of clock time.
    struct ZoneCache {
        private var offsets: [Int: Double] = [:]

        mutating func utc(fromLocal local: Double, zone: TimeZone) -> Double {
            let key = Int((local / 1800).rounded(.down))
            if let o = offsets[key] { return local - o }
            let guess = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: local)))
            let o = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: local - guess)))
            offsets[key] = o
            return local - o
        }
    }
}

/// Units as written in column headers: Car Scanner's, and this app's display units.
enum ImportUnit {
    static let footPerMeter = 3.2808399
    static let hpPerKW = 1.34102209
    static let standardGravity = 9.80665

    /// The stored unit a header unit converts to, and how. nil = not a unit we know.
    static func parse(_ text: String) -> (base: BaseUnit, toBase: @Sendable (Double) -> Double)? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let mpk = UnitConverter.milesPerKm, gpl = UnitConverter.gallonsPerLiter
        switch t {
        case "mph": return (.kmh, { tidy($0 / mpk) })
        case "km/h", "kph": return (.kmh, { $0 })
        case "℉", "°f", "f": return (.celsius, { tidy(($0 - 32) * 5 / 9) })
        case "℃", "°c", "c": return (.celsius, { $0 })
        case "miles", "mile", "mi": return (.km, { tidy($0 / mpk) })
        case "km": return (.km, { $0 })
        case "feet", "ft": return (.meters, { tidy($0 / footPerMeter) })
        case "m": return (.meters, { $0 })
        case "gallon", "gallons", "gal": return (.liters, { tidy($0 / gpl) })
        case "l", "liters", "litres": return (.liters, { $0 })
        case "gal./h", "gal/h": return (.litersPerHour, { tidy($0 / gpl) })
        case "l/h": return (.litersPerHour, { $0 })
        case "mpg": return (.kmPerLiter, { tidy($0 * gpl / mpk) })
        case "km/l": return (.kmPerLiter, { $0 })
        case "l/100 km", "l/100km": return (.kmPerLiter, { $0 > 0 ? tidy(100 / $0) : .infinity })
        case "kpa": return (.kpa, { $0 })
        case "bar": return (.kpa, { tidy($0 * 100) })
        case "psi": return (.kpa, { tidy($0 / 0.145037738) })
        case "pa": return (.pascal, { $0 })
        case "%": return (.percent, { $0 })
        case "v": return (.volts, { $0 })
        case "ma": return (.milliamps, { $0 })
        case "g/sec", "g/s": return (.gramsPerSecond, { $0 })
        case "rpm": return (.rpm, { $0 })
        case "°": return (.degrees, { $0 })
        case "hp": return (.kilowatts, { tidy($0 / hpPerKW) })
        case "kw": return (.kilowatts, { $0 })
        case "g": return (.metersPerSecond2, { tidy($0 * standardGravity) })
        case "m/s²", "m/s2": return (.metersPerSecond2, { $0 })
        case "s", "sec": return (.seconds, { $0 })
        case "min": return (.minutes, { $0 })
        case "afr": return (.lambda, { tidy($0 / UnitConverter.stoichiometricAFR) })
        case "λ": return (.lambda, { $0 })
        case "rpm/mph": return (.rpmPerKmh, { tidy($0 * mpk) })
        case "rpm/(km/h)", "rpm per km/h": return (.rpmPerKmh, { $0 })
        case "n·m", "nm": return (.newtonMeters, { $0 })
        default: return nil
        }
    }

    /// A stored unit from its symbol, as the raw export writes it.
    static func base(forSymbol symbol: String) -> BaseUnit {
        BaseUnit.allCases.first { $0.symbol == symbol } ?? .raw
    }

    /// Drops float noise from unit round trips (16.999999999 -> 17).
    static func tidy(_ v: Double) -> Double {
        guard v.isFinite, abs(v) < 1e9 else { return v }
        return (v * 1_000_000).rounded() / 1_000_000
    }
}

/// Just enough CSV for these files: comma-separated, optional double quotes, one record per line.
enum CSVText {
    static func lines(_ text: String) -> [Substring] {
        var out: [Substring] = []
        let u = text.utf8
        var start = u.startIndex
        var i = start
        while i != u.endIndex {
            if u[i] == 0x0A {
                appendLine(text, start, i, &out)
                start = u.index(after: i)
            }
            i = u.index(after: i)
        }
        appendLine(text, start, u.endIndex, &out)
        return out
    }

    private static func appendLine(_ text: String, _ start: String.Index, _ end: String.Index, _ out: inout [Substring]) {
        var e = end
        if e > start, text.utf8[text.utf8.index(before: e)] == 0x0D { e = text.utf8.index(before: e) }
        if e > start { out.append(text[start..<e]) }
    }

    static func fields(_ line: Substring) -> [Substring] {
        let u = line.utf8
        guard u.contains(0x22) else {
            var out: [Substring] = []
            var start = u.startIndex
            var i = start
            while i != u.endIndex {
                if u[i] == 0x2C {
                    out.append(line[start..<i])
                    start = u.index(after: i)
                }
                i = u.index(after: i)
            }
            out.append(line[start..<u.endIndex])
            return out
        }
        var out: [Substring] = []
        var field = ""
        var quoted = false
        var chars = line.makeIterator()
        while let c = chars.next() {
            if quoted {
                if c == "\"" {
                    // A doubled quote is a literal quote; a single one ends the quoted part.
                    var lookahead = chars
                    if lookahead.next() == "\"" {
                        field.append("\"")
                        chars = lookahead
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                out.append(Substring(field))
                field = ""
            } else {
                field.append(c)
            }
        }
        out.append(Substring(field))
        return out
    }
}
