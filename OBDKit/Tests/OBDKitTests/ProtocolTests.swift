import XCTest
@testable import OBDKit

final class ReadOnlyGuardTests: XCTestCase {
    func testAllowsSetupAndReads() throws {
        for cmd in ["ATZ", "ATE0", "ATH1", "ATSP0", "ATSH7E0", "ATCRA7E8", "ATST32", "ATRV", "ATDPN",
                    "0100", "010C0D05041110", "A800000113", "2210A6", "03", "07", "0A", "atz"] {
            XCTAssertNoThrow(try ReadOnlyGuard.check(cmd), cmd)
        }
    }

    func testRefusesAnythingThatChangesTheCar() {
        let refused = [
            "04",          // clear trouble codes
            "14FFFFFF",    // UDS clear diagnostic information
            "2E10A600",    // write data by identifier
            "3101FF00",    // routine control
            "1003",        // diagnostic session control
            "1101",        // ECU reset
            "2701",        // security access
            "B800000100",  // SSM write
            "A801000113",  // SSM read with a non-zero mode byte
            "22F190",      // VIN identifier
            "ATMA",        // monitor all (not a write, but floods the link)
            "ATWS", "ATPP0CSV00", "ATSH", "", " ", "0100 ", "01\r04", "ZZ",
        ]
        for cmd in refused {
            XCTAssertThrowsError(try ReadOnlyGuard.check(cmd), cmd.debugDescription)
        }
    }

    func testSessionRefusesBeforeSending() async throws {
        let sim = SimulatedAdapter(latency: 0)
        let session = ELMSession(transport: sim)
        do {
            _ = try await session.send("04")
            XCTFail("clear-codes request was sent")
        } catch is ReadOnlyGuard.Refusal {}
        XCTAssertTrue(sim.received.isEmpty)
    }
}

final class ReplyParsingTests: XCTestCase {
    func testSingleFrame() {
        let r = ELMReply.fake("0105", "7E80341057A\r\r")
        let c = ReplyClassifier.classify(r, request: "0105")
        XCTAssertEqual(c.status, .answers)
        XCTAssertEqual(c.responder, 0x7E8)
        XCTAssertEqual(c.payload, [0x41, 0x05, 0x7A])
    }

    func testMultiFramePackedReply() {
        // Real reply to 010C0D05041110 from the 2026-10-01 bench run.
        let r = ELMReply.fake("010C0D05041110", "7E8100F410C0A820D00\r7E82105830400112510\r7E822011A0000000000\r\r")
        let msgs = ISOTP.messages(from: r.lines)
        XCTAssertEqual(msgs[0x7E8]?.first, [0x41, 0x0C, 0x0A, 0x82, 0x0D, 0x00, 0x05, 0x83, 0x04, 0x00, 0x11, 0x25, 0x10, 0x01, 0x1A])
        let values = StandardPIDs.split(msgs[0x7E8]!.first!)
        XCTAssertEqual(Set(values.keys), [0x0C, 0x0D, 0x05, 0x04, 0x11, 0x10])
        XCTAssertEqual(values[0x10], [0x01, 0x1A])
    }

    func testTwoResponders() {
        let r = ELMReply.fake("0100", "SEARCHING...\r7E8064100BE3FA813\r7E906410080000001\r\r")
        let msgs = ISOTP.messages(from: r.lines)
        XCTAssertEqual(msgs.keys.sorted(), [0x7E8, 0x7E9])
        XCTAssertEqual(ReplyClassifier.classify(r, request: "0100", expectFrom: 0x7E9).responder, 0x7E9)
    }

    func testNegativeSilentAndErrors() {
        XCTAssertEqual(ReplyClassifier.classify(.fake("A80000004A", "7E9037FA813\r\r"), request: "A80000004A").status, .negative)
        XCTAssertEqual(ReplyClassifier.classify(.fake("A80000004A", "7E9037FA813\r\r"), request: "A80000004A").nrc, 0x13)
        XCTAssertEqual(ReplyClassifier.classify(.fake("220005", "7E8037F2211\r\r"), request: "220005").status, .notSupported)
        XCTAssertEqual(ReplyClassifier.classify(.fake("220005", "7E8037F2278\r\r"), request: "220005").status, .pending)
        XCTAssertEqual(ReplyClassifier.classify(.fake("220005", "NO DATA\r\r"), request: "220005").status, .silent)
        XCTAssertEqual(ReplyClassifier.classify(.fake("0100", "SEARCHING...\rUNABLE TO CONNECT\r\r"), request: "0100").status, .adapterError)
        XCTAssertEqual(ReplyClassifier.classify(.fake("0100", "CAN ERROR\r\r"), request: "0100").status, .adapterError)
        let timedOut = ELMReply(command: "0100", text: "", elapsed: 3, timedOut: true)
        XCTAssertEqual(ReplyClassifier.classify(timedOut, request: "0100").status, .noReply)
    }

    func testEchoIsDropped() {
        XCTAssertEqual(ELMReply.fake("ATE0", "ATE0\rOK\r\r").lines, ["OK"])
        XCTAssertTrue(ELMReply.fake("ATE0", "ATE0\rOK\r\r").isOK)
    }
}

final class StandardPIDTests: XCTestCase {
    func decode(_ pid: UInt8, _ data: [UInt8]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: StandardPIDs.all[pid]!.decode(data).map { ($0.0.rawValue, $0.1) })
    }

    func testPublishedExamples() {
        XCTAssertEqual(decode(0x0C, [0x0C, 0x9C])["rpm"], 807)
        XCTAssertEqual(decode(0x05, [0x82])["coolant_temp"], 90)
        XCTAssertEqual(decode(0x0D, [0x64])["speed"], 100)
        XCTAssertEqual(decode(0x10, [0x01, 0x1A])["maf"]!, 2.82, accuracy: 1e-9)
        XCTAssertEqual(decode(0x42, [0x36, 0x2B])["module_voltage"]!, 13.867, accuracy: 1e-9)
        XCTAssertEqual(decode(0x06, [0x80])["stft_b1"], 0)
        XCTAssertEqual(decode(0x0E, [0x80])["timing_advance"], 0)
        XCTAssertEqual(decode(0x32, [0xFF, 0x00])["evap_pressure"], -64)
        XCTAssertEqual(decode(0x44, [0x80, 0x00])["commanded_eq_ratio"], 1)
        XCTAssertEqual(decode(0x3C, [0x13, 0x88])["cat_temp_b1s1"], 460)
        XCTAssertEqual(decode(0x01, [0x83, 0x07, 0x65, 0x00]), ["mil_on": 1, "dtc_count": 3])
        XCTAssertNil(decode(0x15, [0x82, 0xFF])["o2_b1s2_trim"])
        XCTAssertEqual(decode(0x15, [0x82, 0xFF])["o2_b1s2_voltage"], 0.65)
    }

    func testSupportBitmapsFromTheCar() {
        // 7E8 replies from the 2026-10-01 bench run.
        let pids = StandardPIDs.supported(base: 0x00, bitmap: [0xBE, 0x3F, 0xA8, 0x13])
            .union(StandardPIDs.supported(base: 0x20, bitmap: [0x90, 0x1F, 0xF0, 0x11]))
            .union(StandardPIDs.supported(base: 0x40, bitmap: [0xFE, 0xDC, 0x80, 0x41]))
            .union(StandardPIDs.supported(base: 0x60, bitmap: [0x08, 0x00, 0x00, 0x00]))
        XCTAssertEqual(pids.count, 47)
        let data = pids.filter { !StandardPIDs.isSupportBitmap($0) }
        XCTAssertEqual(data.count, 44)
        for pid in [0x05, 0x0C, 0x2F, 0x46, 0x49, 0x4A, 0x3C, 0x65] as [UInt8] { XCTAssertTrue(pids.contains(pid), hex2(pid)) }
        // Everything the car supports can be decoded and located in a packed reply.
        for pid in data {
            XCTAssertNotNil(StandardPIDs.lengths[pid], hex2(pid))
            XCTAssertNotNil(StandardPIDs.all[pid], hex2(pid))
        }
    }
}

final class ProfileTests: XCTestCase {
    func testEmbeddedProfileMatchesJSONFile() throws {
        let url = Fixtures.repoRoot.appendingPathComponent("profiles/subaru-outback-2010-25i-cvt.json")
        let fromFile = try VehicleProfile.decode(Data(contentsOf: url))
        XCTAssertEqual(BuiltInProfiles.profile(id: fromFile.id), fromFile, "run tools/embed_profiles.py")
        XCTAssertEqual(BuiltInProfiles.all.count, try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasSuffix(".json") }.count)
    }

    func testSubaruScalingAgainstBenchReplies() throws {
        let p = try XCTUnwrap(BuiltInProfiles.profile(id: "subaru-outback-2010-25i-cvt"))
        func s(_ id: String) -> ProfileSensor { p.sensors.first { $0.id == id }! }
        XCTAssertEqual(s("oil_temp").request, "A800000113")
        XCTAssertEqual(s("oil_temp").decode([0x78]), 80)
        XCTAssertEqual(s("cvt_fluid_temp").decode([0x6E]), 70)
        XCTAssertEqual(s("turbine_speed").decode([0x14]), 640)
        XCTAssertEqual(s("front_rear_rotation_ratio").decode([0x80])!, 1.024, accuracy: 1e-9)
        XCTAssertEqual(s("lockup_duty").decode([199]), 99.5)
        XCTAssertEqual(s("rear_wheel_speed_tcm").enabled, false)
        XCTAssertEqual(p.sensors.count, 12)
        // E8 + value byte.
        XCTAssertEqual(s("oil_temp").valueBytes(fromPositive: [0xE8, 0x78]), [0x78])
    }

    func testValidation() {
        let bad = #"{"format":1,"id":"x","name":"x","sensors":[{"id":"a","name":"a","module":"7E0","ssm":"0001","unit":"raw","status":"raw"}]}"#
        XCTAssertThrowsError(try VehicleProfile.decode(Data(bad.utf8)))
        let vin = #"{"format":1,"id":"x","name":"x","sensors":[{"id":"a","name":"a","module":"7E0","did":"F190","unit":"raw","status":"raw"}]}"#
        XCTAssertThrowsError(try VehicleProfile.decode(Data(vin.utf8)))
        let signed = ProfileSensor(id: "t", name: "t", module: "7E0", ssm: "000001", did: nil, bytes: 2, signed: true, scale: 0.5,
                                   offset: nil, unit: .degrees, category: nil, period: nil, status: "raw", enabled: nil, range: nil, evidence: nil)
        XCTAssertEqual(signed.decode([0xFF, 0xFE]), -1)
    }
}

final class TroubleCodeTests: XCTestCase {
    func testDecode() {
        XCTAssertEqual(TroubleCodes.decode(0x03, 0x01), "P0301")
        XCTAssertEqual(TroubleCodes.decode(0x41, 0x23), "C0123")
        XCTAssertEqual(TroubleCodes.decode(0xC1, 0x00), "U0100")
        XCTAssertEqual(TroubleCodes.decode(0x81, 0xAB), "B01AB")
        XCTAssertNil(TroubleCodes.decode(0, 0))
    }

    func testParseCountedReply() {
        let r = ELMReply.fake("03", "7E8064302030101130000\r7E9024300\r\r")
        let codes = TroubleCodes.parse(r, kind: .stored)
        XCTAssertEqual(codes.map(\.code), ["P0301", "P0113"])
        XCTAssertEqual(Set(codes.map(\.module)), ["7E8"])
    }
}
