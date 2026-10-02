import Foundation
@testable import OBDKit

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Exchange {
        let command: String
        let reply: String
        let ms: Double
        let timedOut: Bool
    }

    /// Reads a recorded TX/RX trace (see the fixture header for the format).
    static func trace(_ name: String) throws -> [Exchange] {
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        var out: [Exchange] = []
        var pendingTX: String?
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            if line.hasPrefix("TX ") {
                pendingTX = String(line.dropFirst(3))
            } else if line.hasPrefix("RX "), let tx = pendingTX {
                let parts = line.dropFirst(3).split(separator: " ", maxSplits: 2)
                let json = Data(parts[2].utf8)
                let reply = try JSONDecoder().decode(String.self, from: json)
                out.append(Exchange(command: tx, reply: reply, ms: Double(parts[0]) ?? 0, timedOut: parts[1] == "T"))
                pendingTX = nil
            }
        }
        return out
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("obdkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Answers each command with the next recorded reply to that same command (the last one
/// repeats), so code that sends a different order than the recording still gets real replies.
final class ReplayTransport: OBDTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8]) -> Void)?
    private var replies: [String: [String]] = [:]
    private var used: [String: Int] = [:]
    private(set) var sent: [String] = []

    init(_ exchanges: [Fixtures.Exchange]) {
        for e in exchanges where !e.timedOut { replies[e.command, default: []].append(e.reply) }
    }

    var isConnected: Bool { true }

    func setReceiveHandler(_ handler: @escaping @Sendable ([UInt8]) -> Void) { lock.locked { self.handler = handler } }

    func write(_ bytes: [UInt8]) async throws {
        let cmd = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        let (h, reply): ((@Sendable ([UInt8]) -> Void)?, String) = lock.locked {
            sent.append(cmd)
            let list = replies[cmd] ?? []
            let i = used[cmd, default: 0]
            used[cmd] = i + 1
            let r = list.isEmpty ? "NO DATA\r\r" : list[min(i, list.count - 1)]
            return (handler, r)
        }
        Task { h?(Array((reply + ">").utf8)) }
    }
}

extension ELMReply {
    static func fake(_ command: String, _ text: String) -> ELMReply {
        ELMReply(command: command, text: text, elapsed: 0.1, timedOut: false)
    }
}
