import XCTest
@testable import OBDKit

final class RecordingTests: XCTestCase {
    func testRecordsAndSurvivesACrash() throws {
        let root = try Fixtures.tempDirectory()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let meta = TripMeta(id: TripMeta.id(for: t0, timeZone: TimeZone(identifier: "America/Denver")!), startedAt: t0, appVersion: "test")
        XCTAssertEqual(meta.id, "2026-09-21_08-13-20")
        let rec = try TripRecorder.start(root: root, meta: meta, traceEnabled: true)
        rec.record([Sample("rpm", 700, t0), Sample("coolant_temp", 85.5, t0.addingTimeInterval(0.1))])
        rec.event("connected", "VEEPEAK, ELM327 v2.2", at: t0)
        rec.trace(TraceLine(time: t0, kind: .tx, text: "010C", elapsed: nil, timedOut: false))
        rec.record([Sample("rpm", 712.25, t0.addingTimeInterval(0.4))])
        rec.flush(sync: true)
        // No finish(): the app was killed. Append a torn line as a crash mid-write would.
        let samples = rec.directory.appendingPathComponent(TripFiles.samples)
        let h = try FileHandle(forWritingTo: samples)
        try h.seekToEnd()
        try h.write(contentsOf: Data("1790000001000,rp".utf8))
        try h.close()

        let trip = try TripData.load(rec.directory)
        XCTAssertEqual(trip.series["rpm"]?.map(\.value), [700, 712.25])
        XCTAssertEqual(trip.series["coolant_temp"]?.first?.value, 85.5)
        XCTAssertEqual(trip.events.first?.kind, "connected")
        XCTAssertEqual(trip.events.first?.detail, "VEEPEAK, ELM327 v2.2")
        XCTAssertNil(trip.meta.endedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.directory.appendingPathComponent(TripFiles.trace).path))
    }

    func testResumeAppendsASegment() throws {
        let root = try Fixtures.tempDirectory()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let rec = try TripRecorder.start(root: root, meta: TripMeta(id: "trip", startedAt: t0, appVersion: "test"), traceEnabled: false)
        rec.record([Sample("speed", 50, t0)])
        rec.finish(at: t0.addingTimeInterval(60))
        let again = try TripRecorder.resume(directory: rec.directory, at: t0.addingTimeInterval(120), traceEnabled: false)
        again.record([Sample("speed", 60, t0.addingTimeInterval(121))])
        again.finish(at: t0.addingTimeInterval(180))
        let trip = try TripData.load(rec.directory)
        XCTAssertEqual(trip.series["speed"]?.count, 2)
        XCTAssertEqual(trip.meta.segments.count, 2)
        XCTAssertEqual(trip.meta.endedAt, t0.addingTimeInterval(180))
    }

    func testLoadLeavesOutImpossibleTimestamps() throws {
        let root = try Fixtures.tempDirectory()
        let t0 = Date().addingTimeInterval(-600)
        let rec = try TripRecorder.start(root: root, meta: TripMeta(id: "trip", startedAt: t0, appVersion: "test"), traceEnabled: false)
        rec.record([Sample("speed", 50, t0), Sample("speed", 52, t0.addingTimeInterval(1)),
                    // A sensor clock gone wrong: days ahead, and days behind.
                    Sample(PhoneSignals.gravityX, 1, Date().addingTimeInterval(3 * 86400)),
                    Sample(PhoneSignals.gravityY, 1, t0.addingTimeInterval(-2 * 86400))])
        rec.finish(at: t0.addingTimeInterval(1))
        let trip = try TripData.load(rec.directory)
        XCTAssertEqual(trip.discardedReadings, 2)
        XCTAssertEqual(trip.series["speed"]?.count, 2)
        XCTAssertNil(trip.series[PhoneSignals.gravityX])
        XCTAssertNil(trip.series[PhoneSignals.gravityY])
        XCTAssertLessThan(trip.end.timeIntervalSince(trip.start), 2)
    }

    func testNumberFormat() {
        XCTAssertEqual(TripFiles.format(700), "700")
        XCTAssertEqual(TripFiles.format(-40), "-40")
        XCTAssertEqual(TripFiles.format(0.1), "0.1")
        XCTAssertEqual(TripFiles.format(39.7828582), "39.7828582")
        XCTAssertEqual(TripFiles.format(1.0 / 3), "0.3333333")
    }
}

final class ExportTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let denver = TimeZone(identifier: "America/Denver")!

    func trip(_ series: [SignalID: [TimedValue]]) -> TripData {
        TripData(meta: TripMeta(id: "t", startedAt: t0, appVersion: "test"), series: series)
    }

    var infos: [SignalID: SignalInfo] {
        Dictionary(uniqueKeysWithValues: StandardPIDs.signalInfos.map { ($0.id, $0) })
    }

    func testWideExportShowsAFreezeAsAGap() {
        // RPM every 0.25 s, then nothing for 36 s (like the 2026-09-17 freeze), then back.
        var rpm: [TimedValue] = []
        for i in 0..<40 { rpm.append(TimedValue(t0.addingTimeInterval(Double(i) * 0.25), 1136)) }
        for i in 0..<40 { rpm.append(TimedValue(t0.addingTimeInterval(46 + Double(i) * 0.25), 1500)) }
        let csv = CSVExport.wide(trip(["rpm": rpm]), infos: infos, prefs: .us, step: 0.5, timeZone: denver)
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().filter { !$0.isEmpty }
        XCTAssertEqual(csv.split(separator: "\n").first, "time,elapsed_s,Engine speed (rpm)")
        let cells = rows.map { $0.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? "" }
        let empty = cells.filter { $0.isEmpty }.count
        // ~36 s of 0.5 s rows are blank instead of repeating 1136.
        XCTAssertGreaterThan(empty, 65)
        XCTAssertLessThan(empty, 76)
        XCTAssertEqual(cells.first, "1136.0")
        XCTAssertTrue(rows.first!.hasPrefix("2026-09-21T08:13:20.000-06:00,0.0,"))
    }

    func testWideExportUnitsAndAge() {
        let csv = CSVExport.wide(trip(["coolant_temp": [TimedValue(t0, 100), TimedValue(t0.addingTimeInterval(1), 100)]]),
                                 infos: infos, prefs: .us, step: 0.5, includeAge: true, timeZone: denver)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines[0], "time,elapsed_s,Coolant temperature (°F),Coolant temperature age (s)")
        XCTAssertTrue(lines[1].hasSuffix(",212.0,0.0"))
        XCTAssertTrue(lines[2].hasSuffix(",212.0,0.5"))
    }

    func testRawExport() {
        let csv = CSVExport.raw(trip(["speed": [TimedValue(t0, 50)], "rpm": [TimedValue(t0, 1500)]]), infos: infos, timeZone: denver)
        XCTAssertEqual(csv.split(separator: "\n"), [
            "time,elapsed_s,signal,name,value,unit",
            "2026-09-21T08:13:20.000-06:00,0.000,rpm,Engine speed,1500,rpm",
            "2026-09-21T08:13:20.000-06:00,0.000,speed,Vehicle speed,50,km/h",
        ])
    }

    func testInfluxLines() {
        let lines = InfluxLineProtocol.lines(trip(["coolant_temp": [TimedValue(t0, 85.5)]]),
                                             tags: ["vehicle": "my car", "trip_id": "2026-09-21_08-13-20"])
        XCTAssertEqual(lines, [#"trip,trip_id=2026-09-21_08-13-20,vehicle=my\ car coolant_temp=85.5 1790000000000"#])
    }

    func testSummary() {
        var speed: [TimedValue] = [], maf: [TimedValue] = []
        var derived = DerivedSignals()
        var fuel: [TimedValue] = []
        for i in 0...3600 {
            let t = t0.addingTimeInterval(Double(i))
            speed.append(TimedValue(t, 100))
            maf.append(TimedValue(t, 20))
            for s in derived.ingest(Sample("maf", 20, t)) where s.signal == DerivedSignals.fuelRate { fuel.append(TimedValue(s.time, s.value)) }
        }
        let summary = trip(["speed": speed, "maf": maf, DerivedSignals.fuelRate: fuel]).summarize()
        XCTAssertEqual(summary.distanceKm, 100, accuracy: 0.01)
        // 20 g/s air at λ 1 = 20/14.7 g/s fuel = 6.57 L/h.
        XCTAssertEqual(summary.fuelLiters, 20 / 14.7 / 745 * 3600, accuracy: 0.01)
        XCTAssertEqual(derived.fuelLiters, summary.fuelLiters, accuracy: 0.01)
    }
}

final class DerivedTests: XCTestCase {
    func testDerivedValues() {
        var d = DerivedSignals()
        let t = Date()
        _ = d.ingest(Sample("baro", 84, t))
        XCTAssertEqual(d.ingest(Sample("map", 30, t)).first { $0.signal == DerivedSignals.boost }?.value, -54)
        _ = d.ingest(Sample("speed", 80, t))
        let fromMAF = d.ingest(Sample("maf", 10, t))
        XCTAssertEqual(fromMAF.first { $0.signal == DerivedSignals.fuelRate }!.value, 10 / 14.7 / 745 * 3600, accuracy: 1e-9)
        XCTAssertNotNil(fromMAF.first { $0.signal == DerivedSignals.fuelEconomy })
        _ = d.ingest(Sample("rpm", 2000, t))
        XCTAssertEqual(d.ingest(Sample("turbine_speed", 1856, t)).first?.value, 144)
        _ = d.ingest(Sample("speed", 82, t.addingTimeInterval(1)))
        XCTAssertEqual(d.distanceKm, 81.0 / 3600, accuracy: 1e-9)
    }

    func testUnitConversion() {
        XCTAssertEqual(UnitConverter.display(100, unit: .celsius, prefs: .us).text, "212")
        XCTAssertEqual(UnitConverter.display(100, unit: .kmh, prefs: .us).text, "62")
        XCTAssertEqual(UnitConverter.display(1, unit: .lambda, prefs: .us).textWithUnit, "14.70 AFR")
        XCTAssertEqual(UnitConverter.toBase(212, unit: .celsius, prefs: .us), 100, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.display(10, unit: .kmPerLiter, prefs: .us).value, 23.52, accuracy: 0.01)
    }
}
