import Foundation

/// Everything the adapter sent back for one command, up to its `>` prompt.
public struct ELMReply: Sendable, Equatable {
    public let command: String
    public let text: String
    public let elapsed: Double
    public let timedOut: Bool

    public init(command: String, text: String, elapsed: Double, timedOut: Bool) {
        self.command = command
        self.text = text
        self.elapsed = elapsed
        self.timedOut = timedOut
    }

    static let noise = ["SEARCHING", "BUSINIT"]

    /// Non-empty reply lines with the echo removed, trimmed.
    public var rawLines: [String] {
        text.replacingOccurrences(of: "\n", with: "\r")
            .split(separator: "\r", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.replacingOccurrences(of: " ", with: "").uppercased() != command.uppercased() }
    }

    /// Reply lines without echo, spaces or search chatter, uppercased.
    public var lines: [String] {
        rawLines
            .map { $0.replacingOccurrences(of: " ", with: "").uppercased() }
            .filter { line in !Self.noise.contains(where: { line.hasPrefix($0) }) }
    }

    /// Single-line text for AT replies ("OK", "ELM327 v2.2", "14.0V").
    public var summary: String { rawLines.joined(separator: " | ") }

    public var isOK: Bool { lines.contains("OK") }
}

/// ISO 15765-2 reassembly for replies printed with headers on (ATH1), 11-bit IDs and
/// auto-formatting on: each line is a 3-digit CAN ID followed by the frame's data bytes,
/// PCI byte included.
public enum ISOTP {
    public static func messages(from lines: [String]) -> [UInt16: [[UInt8]]] {
        var done: [UInt16: [[UInt8]]] = [:]
        var partial: [UInt16: (length: Int, data: [UInt8])] = [:]
        for line in lines {
            guard line.count >= 5, (line.count - 3) % 2 == 0,
                  let id = UInt16(line.prefix(3), radix: 16),
                  let data = Hex.bytes(line.dropFirst(3)), !data.isEmpty else { continue }
            switch data[0] >> 4 {
            case 0: // single frame
                let n = Int(data[0] & 0x0F)
                done[id, default: []].append(Array(data.dropFirst().prefix(n)))
            case 1: // first frame
                guard data.count >= 2 else { continue }
                let n = Int(data[0] & 0x0F) << 8 | Int(data[1])
                partial[id] = (n, Array(data.dropFirst(2)))
            case 2: // consecutive frame
                guard partial[id] != nil else { continue }
                partial[id]!.data.append(contentsOf: data.dropFirst())
            default:
                continue
            }
            if let p = partial[id], p.data.count >= p.length {
                done[id, default: []].append(Array(p.data.prefix(p.length)))
                partial[id] = nil
            }
        }
        return done
    }
}

public enum ReplyStatus: String, Codable, Sendable, CaseIterable {
    case answers
    case notSupported = "not_supported"
    case conditional
    case negative
    case pending
    case silent
    case adapterError = "adapter_error"
    case noReply = "no_reply"
    case unexpected
}

public struct ClassifiedReply: Sendable, Equatable {
    public var status: ReplyStatus
    public var responder: UInt16?
    /// Positive (or negative-response) payload, service byte first.
    public var payload: [UInt8]
    public var nrc: UInt8?
    public var detail: String

    public init(status: ReplyStatus, responder: UInt16? = nil, payload: [UInt8] = [], nrc: UInt8? = nil, detail: String = "") {
        self.status = status
        self.responder = responder
        self.payload = payload
        self.nrc = nrc
        self.detail = detail
    }
}

public enum ReplyClassifier {
    static let adapterErrors = ["CANERROR", "BUFFERFULL", "STOPPED", "UNABLETOCONNECT", "BUSERROR",
                                "BUSBUSY", "FBERROR", "DATAERROR", "RXERROR", "ACTALERT", "LVRESET", "ERR"]
    static let nrcNotSupported: Set<UInt8> = [0x11, 0x12, 0x31]
    static let nrcConditional: Set<UInt8> = [0x21, 0x22, 0x33, 0x7E, 0x7F]

    /// Classifies the reply to a read request (`request` is the hex request without any count suffix).
    /// `expectFrom` restricts which responder counts; nil accepts any.
    public static func classify(_ reply: ELMReply, request: String, expectFrom: UInt16? = nil) -> ClassifiedReply {
        guard let req = Hex.bytes(request), let service = req.first,
              let positive = ReadOnlyGuard.readServices[service] else {
            return ClassifiedReply(status: .unexpected, detail: "not a read request")
        }
        let messages = ISOTP.messages(from: reply.lines)
        var negative: (UInt16, [UInt8])?
        for id in messages.keys.sorted() where expectFrom == nil || id == expectFrom {
            for p in messages[id]! {
                if p.first == positive && keyMatches(service: service, request: req, payload: p) {
                    return ClassifiedReply(status: .answers, responder: id, payload: p)
                }
                if p.count >= 3 && p[0] == 0x7F && p[1] == service {
                    negative = (id, p)
                }
            }
        }
        if let (id, p) = negative {
            let nrc = p[2]
            let status: ReplyStatus
            if nrc == 0x78 { status = .pending }
            else if nrcNotSupported.contains(nrc) { status = .notSupported }
            else if nrcConditional.contains(nrc) { status = .conditional }
            else { status = .negative }
            return ClassifiedReply(status: status, responder: id, payload: p, nrc: nrc)
        }
        let joined = reply.lines.joined()
        if reply.timedOut { return ClassifiedReply(status: .noReply, detail: String(joined.prefix(80))) }
        if joined.isEmpty || joined.contains("NODATA") { return ClassifiedReply(status: .silent) }
        if joined == "?" || adapterErrors.contains(where: { joined.contains($0) }) {
            return ClassifiedReply(status: .adapterError, detail: String(joined.prefix(80)))
        }
        return ClassifiedReply(status: .unexpected, detail: String(joined.prefix(80)))
    }

    static func keyMatches(service: UInt8, request: [UInt8], payload: [UInt8]) -> Bool {
        switch service {
        case 0x22: return payload.count >= 3 && request.count >= 3 && payload[1] == request[1] && payload[2] == request[2]
        case 0x01: return payload.count > 1 && request.count > 1 && payload[1] == request[1]
        default: return true // SSM A8 replies and trouble-code replies don't echo a key
        }
    }
}
