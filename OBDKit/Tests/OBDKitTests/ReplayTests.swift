import XCTest
@testable import OBDKit

/// Checks the Swift parser against what the real adapter sent on 2026-10-01.
final class ReplayTests: XCTestCase {
    let fixture = "veepeak-idle-2026-10-01.trace"

    func testEveryRecordedReplyClassifies() throws {
        let exchanges = try Fixtures.trace(fixture)
        XCTAssertGreaterThan(exchanges.count, 700)
        var ssm: [String: ReplyStatus] = [:]
        var packedValues = 0
        for e in exchanges {
            let reply = ELMReply(command: e.command, text: e.reply, elapsed: e.ms / 1000, timedOut: e.timedOut)
            if e.command.hasPrefix("A8") && e.command.count == 10 {
                ssm[e.command] = ReplyClassifier.classify(reply, request: e.command).status
            }
            if e.command.hasPrefix("01") && e.command.count == 14 {
                let payload = try XCTUnwrap(ISOTP.messages(from: reply.lines)[0x7E8]?.first, e.reply)
                XCTAssertEqual(StandardPIDs.split(payload).count, 6, e.reply)
                packedValues += 1
            }
        }
        let answering = ssm.filter { $0.value == .answers }.keys.sorted()
        XCTAssertEqual(answering, ["A800000048", "A80000004C", "A80000004D", "A80000004F", "A800000051", "A800000056",
                                   "A8000000F9", "A800000113", "A800000293", "A800000294", "A800000295", "A800000296"])
        XCTAssertEqual(ssm.values.filter { $0 == .negative }.count, 3)
        XCTAssertGreaterThan(packedValues, 50)
    }

    func testIdleValuesArePlausible() throws {
        let exchanges = try Fixtures.trace(fixture)
        let profile = try XCTUnwrap(BuiltInProfiles.profile(id: "subaru-outback-2010-25i-cvt"))
        var rpm: [Double] = [], coolant: [Double] = [], oil: [Double] = []
        for e in exchanges {
            let reply = ELMReply.fake(e.command, e.reply)
            if e.command.hasPrefix("01"), let p = ISOTP.messages(from: reply.lines)[0x7E8]?.first(where: { $0.first == 0x41 }) {
                let data = StandardPIDs.split(p)
                if let d = data[0x0C] { rpm.append(StandardPIDs.all[0x0C]!.decode(d)[0].1) }
                if let d = data[0x05] { coolant.append(StandardPIDs.all[0x05]!.decode(d)[0].1) }
            }
            if e.command == "A800000113" {
                let c = ReplyClassifier.classify(reply, request: e.command)
                let s = profile.sensors.first { $0.id == "oil_temp" }!
                if let v = s.decode(s.valueBytes(fromPositive: c.payload)) { oil.append(v) }
            }
        }
        XCTAssertTrue(rpm.allSatisfy { (600...900).contains($0) }, "idle rpm \(rpm.min() ?? 0)-\(rpm.max() ?? 0)")
        XCTAssertTrue(coolant.allSatisfy { (75...100).contains($0) })
        XCTAssertFalse(oil.isEmpty)
        XCTAssertTrue(oil.allSatisfy { (60...100).contains($0) })
    }

    func testAdapterSetupAgainstRealReplies() async throws {
        let transport = ReplayTransport(try Fixtures.trace(fixture))
        let session = ELMSession(transport: transport)
        let info = try await AdapterSetup.initialize(session)
        XCTAssertEqual(info.identity, "ELM327 v2.2")
        XCTAssertFalse(info.isSTN)
        XCTAssertEqual(info.batteryVoltage, 14.0)
        XCTAssertEqual(info.protocolName, "AUTO, ISO 15765-4 (CAN 11/500)")
        XCTAssertEqual(info.supportedPIDs(responder: 0x7E8).count, 47)
        XCTAssertEqual(info.supportedPIDs(responder: 0x7E9), [0x01, 0x20, 0x21])
        XCTAssertTrue(info.fingerprint.hasPrefix("7E8:00=BE3FA813,20=901FF011,40=FEDC8041,60=08000000;7E9:"))
        // Setup sends nothing outside the read-only allow list.
        for cmd in transport.sent { XCTAssertNoThrow(try ReadOnlyGuard.check(cmd), cmd) }
    }
}
