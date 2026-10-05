import XCTest
@testable import OBDKit

final class ImportTests: XCTestCase {
    let denver = TimeZone(identifier: "America/Denver")!
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 08:13:20 MDT

    func testTripIDsFromFileNames() {
        XCTAssertEqual(TripImport.tripID(fromFileName: "2026-10-05_06-49-31-raw.csv"), "2026-10-05_06-49-31")
        XCTAssertEqual(TripImport.tripID(fromFileName: "2026-10-05_06-49-31.csv"), "2026-10-05_06-49-31")
        XCTAssertEqual(TripImport.tripID(fromFileName: "2026-10-01 15-16-54.csv"), "2026-10-01_15-16-54")
        XCTAssertEqual(TripImport.tripID(fromFileName: "2026-09-03 14-46-15 2.csv"), "2026-09-03_14-46-15")
        XCTAssertNil(TripImport.tripID(fromFileName: "2026-09-02_morning.csv"))
        XCTAssertNil(TripImport.tripID(fromFileName: "activity.csv"))
        XCTAssertNil(TripImport.tripID(fromFileName: "2026-13-02 10-00-00.csv"))
        XCTAssertTrue(TripImport.isRawExport(fileName: "2026-10-05_06-49-31-raw.csv"))
        XCTAssertFalse(TripImport.isRawExport(fileName: "2026-10-05_06-49-31.csv"))
    }

    func testFormatFromHeader() {
        XCTAssertEqual(TripImport.format(ofHeader: ["time", "elapsed_s", "signal", "name", "value", "unit"]), .raw)
        XCTAssertEqual(TripImport.format(ofHeader: ["time", "elapsed_s", "Engine speed (rpm)"]), .table)
        XCTAssertEqual(TripImport.format(ofHeader: ["time", "Engine RPM (rpm)", ""]), .carScanner)
        XCTAssertNil(TripImport.format(ofHeader: ["timestamp_ns", "value"]))
        XCTAssertNil(TripImport.format(ofHeader: ["time"]))
    }

    func testTimeParsing() {
        var zones = TripImport.ZoneCache()
        XCTAssertEqual(TripImport.epochSeconds("2026-09-21T08:13:20.000-06:00", localZone: nil, zones: &zones)!, 1_790_000_000, accuracy: 1e-6)
        XCTAssertEqual(TripImport.epochSeconds("2026-09-21T14:13:20.25Z", localZone: nil, zones: &zones)!, 1_790_000_000.25, accuracy: 1e-6)
        XCTAssertEqual(TripImport.epochSeconds("2026-09-21T16:13:20+0200", localZone: nil, zones: &zones)!, 1_790_000_000, accuracy: 1e-6)
        XCTAssertNil(TripImport.epochSeconds("2026-09-21T08:13:20", localZone: nil, zones: &zones), "no offset and no zone")
        XCTAssertEqual(TripImport.epochSeconds("2026-09-21 08:13:20.5", localZone: denver, zones: &zones)!, 1_790_000_000.5, accuracy: 1e-6)
        XCTAssertEqual(TripImport.secondsOfDay("15:16:54.645")!, 55014.645, accuracy: 1e-6)
        XCTAssertEqual(TripImport.secondsOfDay("9:05:01")!, 32701, accuracy: 1e-6)
        XCTAssertNil(TripImport.secondsOfDay("25:00:00"))
        XCTAssertEqual(TripImport.daysFromCivil(1970, 1, 1), 0)
        XCTAssertEqual(TripImport.daysFromCivil(2000, 3, 1), 11017)
    }

    func testHeaderSplitting() {
        XCTAssertTrue(TripImport.splitHeader("Engine RPM (rpm)") == ("Engine RPM", "rpm"))
        XCTAssertTrue(TripImport.splitHeader("Fuel level input (%) (%)") == ("Fuel level input (%)", "%"))
        XCTAssertTrue(TripImport.splitHeader("# warm-ups since codes cleared ()") == ("# warm-ups since codes cleared", ""))
        XCTAssertTrue(TripImport.splitHeader("Altitude (GPS) (feet)") == ("Altitude (GPS)", "feet"))
        XCTAssertTrue(TripImport.splitHeader("Latitude") == ("Latitude", ""))
        XCTAssertTrue(TripImport.splitHeader("Fuel rate (from airflow) (gal/h)") == ("Fuel rate (from airflow)", "gal/h"))
    }

    func testCSVFields() {
        XCTAssertEqual(CSVText.fields("a,,b"), ["a", "", "b"])
        XCTAssertEqual(CSVText.fields(#""x, y","say ""hi""",3"#), ["x, y", #"say "hi""#, "3"])
        XCTAssertEqual(CSVText.lines("h\r\n1\n\n2"), ["h", "1", "2"])
    }

    // MARK: this app's exports

    func sampleTrip() -> TripData {
        var series: [SignalID: [TimedValue]] = [:]
        for i in 0..<120 {
            let t = t0.addingTimeInterval(Double(i) * 0.5)
            series["rpm", default: []].append(TimedValue(t, 800 + Double(i)))
            if i % 4 == 0 { series["coolant_temp", default: []].append(TimedValue(t.addingTimeInterval(0.137), 85 + Double(i) / 8)) }
            if i % 2 == 0 { series["speed", default: []].append(TimedValue(t.addingTimeInterval(0.25), Double(i / 2))) }
        }
        series["unknown_thing"] = [TimedValue(t0.addingTimeInterval(3), 1.25)]
        var meta = TripMeta(id: TripMeta.id(for: t0, timeZone: denver), startedAt: t0, appVersion: "test")
        meta.signals = [SignalInfo(id: "unknown_thing", name: "Unknown, with comma", unit: .volts, category: .electrical, source: .standard)]
        return TripData(meta: meta, series: series)
    }

    func testRawExportRoundTripsExactly() throws {
        let original = sampleTrip()
        let csv = CSVExport.raw(original, infos: SignalCatalog.infos(for: original), timeZone: denver)
        let imported = try TripImport.parse(Data(csv.utf8), fileName: "2026-09-21_08-13-20-raw.csv", timeZone: .current,
                                            appVersion: "0.1.0 (9)")
        XCTAssertEqual(imported.format, .raw)
        let trip = imported.trip
        XCTAssertEqual(trip.meta.id, "2026-09-21_08-13-20")
        XCTAssertEqual(Set(trip.series.keys), Set(original.series.keys))
        for (id, values) in original.series {
            XCTAssertEqual(trip.series[id]?.map(\.value), values.map(\.value), "\(id)")
            XCTAssertEqual(trip.series[id]?.map { ($0.time.timeIntervalSince1970 * 1000).rounded() },
                           values.map { ($0.time.timeIntervalSince1970 * 1000).rounded() }, "\(id)")
        }
        let unknown = trip.meta.signals.first { $0.id == "unknown_thing" }
        XCTAssertEqual(unknown?.name, "Unknown, with comma")
        XCTAssertEqual(unknown?.unit, .volts)
        XCTAssertEqual(trip.meta.importedFrom, "2026-09-21_08-13-20-raw.csv")
        XCTAssertNotNil(trip.meta.importedAt)
        XCTAssertTrue(trip.meta.isImported)
        XCTAssertEqual(trip.meta.startedAt, original.start)
        XCTAssertEqual(trip.meta.endedAt, original.end)
        XCTAssertEqual(trip.meta.summary?.samples, original.series.values.reduce(0) { $0 + $1.count })
        XCTAssertEqual(trip.events.first?.kind, "imported")
    }

    func testTableExportConvertsBackAndKeepsGaps() throws {
        // Coolant only for the first 20 s, then nothing: the table leaves those cells empty.
        var series: [SignalID: [TimedValue]] = [:]
        for i in 0..<120 {
            let t = t0.addingTimeInterval(Double(i) * 0.5)
            series["rpm", default: []].append(TimedValue(t, 900))
            if i < 40 && i % 2 == 0 { series["coolant_temp", default: []].append(TimedValue(t, 90)) }
            if i % 2 == 0 { series["speed", default: []].append(TimedValue(t, 100)) }
        }
        let original = TripData(meta: TripMeta(id: "t", startedAt: t0, appVersion: "test"), series: series)
        let csv = CSVExport.wide(original, infos: SignalCatalog.infos, prefs: .us, step: 0.5, includeAge: true, timeZone: denver)
        let trip = try TripImport.parse(Data(csv.utf8), fileName: "2026-09-21_08-13-20.csv", appVersion: "test").trip
        XCTAssertEqual(trip.series["coolant_temp"]?.first?.value ?? 0, 90, accuracy: 0.01)
        XCTAssertEqual(trip.series["speed"]?.first?.value ?? 0, 100, accuracy: 0.1, "62.1 mph, one decimal")
        // A held value keeps one reading per second, not one per row.
        XCTAssertEqual(trip.series["rpm"]?.count, 60)
        // Coolant stops when the table's cells go empty instead of running to the end.
        let lastCoolant = trip.series["coolant_temp"]!.last!.time.timeIntervalSince(t0)
        XCTAssertLessThan(lastCoolant, 25)
        XCTAssertNil(trip.series.keys.first { $0.rawValue.contains("age") }, "age columns aren't signals")
        XCTAssertTrue(trip.meta.notes?.contains("table export") == true)
    }

    // MARK: Car Scanner

    /// Shaped like a real export: quoted header with ℉, a trailing empty column, both O2 ratio
    /// columns under one name, running totals, and every value repeated until a new one arrives.
    let carScanner = """
    time,"Vehicle speed (mph)","Engine RPM (rpm)","Engine RPM x1000 (rpm)","Engine coolant temperature (℉)","Oxygen sensor 1 Wide Range Equivalence ratio ()","Oxygen sensor 1 Wide Range Equivalence ratio ()","Oxygen sensor 1 Wide Range Voltage (V)","Oxygen sensor 1 Wide Range Current (mA) (mA)","Distance travelled (Today) (miles)","Fuel used price ($)","Learned ignition timing correction (°)","Latitude","Longtitude","Altitude (GPS) (feet)",
    15:16:54.645,,,,,,,,,,,,,,,
    15:16:55.100,0,812,0.8,190.4,14.7,14.65,3.28,0.01,12.5,0.01,2.8,40.0001,-105.0001,5280,
    15:16:55.400,0,812,0.8,190.4,14.7,14.65,3.28,0.01,12.5,0.01,2.8,40.0001,-105.0001,5280,
    15:16:55.700,0,820,0.8,190.4,14.7,14.65,3.28,0.01,12.5,0.01,2.8,40.0001,-105.0001,5280,
    15:16:56.000,0,820,0.8,190.4,14.7,14.65,3.28,0.01,12.5,0.01,2.8,40.0001,-105.0001,5280,
    15:16:56.300,0,820,0.8,190.4,14.7,14.65,3.28,0.01,12.5,0.01,2.8,40.0001,-105.0001,5280,
    15:16:56.600,31.07,1500,1.5,192.2,14.6,14.65,3.28,0.01,12.5,0.01,2.8,40.0002,-105.0001,5281,
    """

    func testCarScannerExport() throws {
        let result = try TripImport.parse(Data(carScanner.utf8), fileName: "2026-10-01 15-16-54.csv", timeZone: denver, appVersion: "test")
        let trip = result.trip
        XCTAssertEqual(result.format, .carScanner)
        XCTAssertEqual(trip.meta.id, "2026-10-01_15-16-54")
        // 15:16:55.100 MDT = 21:16:55.100 UTC.
        let first = trip.series["rpm"]!.first!
        XCTAssertEqual(first.time.timeIntervalSince1970, epoch("2026-10-01T21:16:55.100Z"), accuracy: 1e-6)
        XCTAssertEqual(first.value, 812)
        // Repeats are thinned: 812 at 55.1 (kept), 55.4 (dropped), 820 at 55.7 (a change), 56.0 and 56.3
        // (held for under a second, dropped), 1500 at 56.6.
        XCTAssertEqual(trip.series["rpm"]!.map(\.value), [812, 820, 1500])
        XCTAssertEqual(trip.series["speed"]!.last!.value, 50, accuracy: 0.01, "31.07 mph")
        XCTAssertEqual(trip.series["coolant_temp"]!.first!.value, 88, accuracy: 0.001, "190.4 °F")
        XCTAssertEqual(trip.series["o2_b1s1_eq_ratio_v"]!.first!.value, 1.0, accuracy: 1e-6, "first ratio column, AFR 14.7")
        XCTAssertEqual(trip.series["o2_b1s1_eq_ratio"]!.first!.value, 14.65 / 14.7, accuracy: 1e-6, "second ratio column")
        XCTAssertEqual(trip.series["o2_b1s1_wr_current"]!.first!.value, 0.01)
        XCTAssertEqual(trip.series["gps_lon"]!.first!.value, -105.0001)
        XCTAssertEqual(trip.series["gps_alt"]!.first!.value, 1609.344, accuracy: 0.001)
        XCTAssertEqual(trip.series["cs_learned_ignition_timing_correction"]?.first?.value, 2.8)
        XCTAssertEqual(trip.meta.signals.first { $0.id == "cs_learned_ignition_timing_correction" }?.unit, .degrees)
        XCTAssertEqual(Set(result.skippedColumns), ["Engine RPM x1000 (rpm)", "Distance travelled (Today) (miles)", "Fuel used price ($)"])
        XCTAssertTrue(trip.meta.notes?.contains("Car Scanner") == true)
        XCTAssertEqual(trip.meta.summary?.maxCoolant ?? 0, 89, accuracy: 0.001)
    }

    func testCarScannerAcrossMidnight() throws {
        let csv = """
        time,"Engine RPM (rpm)"
        23:59:59.000,800
        00:00:01.000,900
        """
        let trip = try TripImport.parse(Data(csv.utf8), fileName: "2026-10-01 23-59-58.csv", timeZone: denver, appVersion: "test").trip
        let times = trip.series["rpm"]!.map(\.time.timeIntervalSince1970)
        XCTAssertEqual(times[1] - times[0], 2, accuracy: 1e-6)
        XCTAssertEqual(times[1], epoch("2026-10-02T06:00:01Z"), accuracy: 1e-6)
    }

    func testOnlyRPMx1000() throws {
        let csv = "time,\"Engine RPM x1000 (rpm)\"\n10:00:00.000,1.4\n"
        let trip = try TripImport.parse(Data(csv.utf8), fileName: "2026-10-01 10-00-00.csv", timeZone: denver, appVersion: "test").trip
        XCTAssertEqual(trip.series["rpm"]?.first?.value, 1400)
    }

    func testErrors() {
        XCTAssertThrowsError(try TripImport.parse(Data("a,b\n1,2\n".utf8), fileName: "x.csv", appVersion: "t")) {
            XCTAssertEqual($0 as? TripImport.ImportError, .unrecognized)
        }
        XCTAssertThrowsError(try TripImport.parse(Data("time,\"Engine RPM (rpm)\"\n10:00:00.000,800\n".utf8),
                                                  fileName: "export.csv", appVersion: "t")) {
            XCTAssertEqual($0 as? TripImport.ImportError, .noDateInFileName("export.csv"))
        }
        XCTAssertThrowsError(try TripImport.parse(Data("time,elapsed_s,signal,name,value,unit\n".utf8),
                                                  fileName: "2026-10-01_10-00-00-raw.csv", appVersion: "t")) {
            XCTAssertEqual($0 as? TripImport.ImportError, .noReadings)
        }
    }

    // MARK: writing

    func testWrittenTripLoadsBackAndIsNotOverwritten() throws {
        let root = try Fixtures.tempDirectory()
        let trip = try TripImport.parse(Data(carScanner.utf8), fileName: "2026-10-01 15-16-54.csv", timeZone: denver, appVersion: "test").trip
        let dir = try TripImport.write(trip, to: root)
        XCTAssertEqual(dir.lastPathComponent, "2026-10-01_15-16-54")
        let loaded = try TripData.load(dir)
        XCTAssertEqual(loaded.meta.id, trip.meta.id)
        XCTAssertEqual(loaded.meta.importedFrom, "2026-10-01 15-16-54.csv")
        XCTAssertEqual(loaded.meta.signals, trip.meta.signals)
        XCTAssertEqual(loaded.meta.summary?.samples, trip.meta.summary?.samples)
        // meta.json keeps whole seconds.
        XCTAssertEqual(loaded.meta.startedAt.timeIntervalSince(trip.meta.startedAt), 0, accuracy: 1)
        XCTAssertNotNil(loaded.meta.endedAt)
        XCTAssertEqual(loaded.series.mapValues { $0.map(\.value) }, trip.series.mapValues { $0.map(\.value) })
        XCTAssertEqual(loaded.events.first?.kind, "imported")
        XCTAssertThrowsError(try TripImport.write(trip, to: root)) {
            XCTAssertEqual($0 as? TripImport.ImportError, .exists("2026-10-01_15-16-54"))
        }
    }

    /// Imports every trip export under a folder of real recordings, which stay out of the
    /// repository: `OBDKIT_IMPORT_DIR=/path/to/exports swift test --filter ImportTests`.
    func testImportsEveryFileInLocalFolder() throws {
        guard let path = ProcessInfo.processInfo.environment["OBDKIT_IMPORT_DIR"] else {
            throw XCTSkip("Set OBDKIT_IMPORT_DIR to a folder of exports to run this.")
        }
        let root = URL(fileURLWithPath: path)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "csv" && TripImport.tripID(fromFileName: $0.lastPathComponent) != nil }
            .sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty)
        var leftOut = Set<String>()
        defer { print("Columns left out across all files:", leftOut.sorted().joined(separator: " | ")) }
        for url in files {
            let started = Date()
            do {
                let r = try TripImport.parse(try Data(contentsOf: url), fileName: url.lastPathComponent, timeZone: denver, appVersion: "test")
                let s = r.trip.meta.summary!
                let line = String(format: "%@ %@ %.1f s parse | %d signals, %d readings, %.0f min, %.1f km, coolant max %@, longest rpm gap %.1f s | skipped %d",
                                  r.trip.meta.id, r.format.rawValue, Date().timeIntervalSince(started), r.trip.series.count, s.samples,
                                  s.duration / 60, s.distanceKm, s.maxCoolant.map { String(format: "%.1f °C", $0) } ?? "–",
                                  s.longestRPMGap, r.skippedColumns.count)
                print(url.lastPathComponent, "->", line)
                leftOut.formUnion(r.skippedColumns)
                let extras = r.trip.meta.signals.filter { $0.source == .imported }.map(\.name)
                if !extras.isEmpty { print("    kept under own name:", extras.joined(separator: " | ")) }
            } catch {
                XCTFail("\(url.lastPathComponent): \(error)")
            }
        }
    }

    private func epoch(_ iso: String) -> Double {
        var zones = TripImport.ZoneCache()
        return TripImport.epochSeconds(Substring(iso), localZone: nil, zones: &zones)!
    }
}
