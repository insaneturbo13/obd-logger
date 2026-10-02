import Foundation

public struct TroubleCode: Codable, Sendable, Hashable, Comparable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case stored, pending, permanent
        var service: UInt8 {
            switch self {
            case .stored: return 0x03
            case .pending: return 0x07
            case .permanent: return 0x0A
            }
        }
    }

    public var code: String
    public var module: String
    public var kind: Kind

    public static func < (a: TroubleCode, b: TroubleCode) -> Bool {
        (a.kind.rawValue, a.code, a.module) < (b.kind.rawValue, b.code, b.module)
    }
}

/// Reads stored, pending and permanent codes (services 03, 07, 0A). Read-only: clearing
/// codes is deliberately not possible through this type.
public enum TroubleCodes {
    /// "P0301" from the two bytes; nil for the 0000 padding.
    public static func decode(_ a: UInt8, _ b: UInt8) -> String? {
        guard a != 0 || b != 0 else { return nil }
        let letter = ["P", "C", "B", "U"][Int(a >> 6)]
        return letter + String((a >> 4) & 0x3) + String(a & 0x0F, radix: 16, uppercase: true)
            + String(b >> 4, radix: 16, uppercase: true) + String(b & 0x0F, radix: 16, uppercase: true)
    }

    /// Codes per responder from a reply to service 03/07/0A.
    public static func parse(_ reply: ELMReply, kind: TroubleCode.Kind) -> [TroubleCode] {
        let positive = kind.service + 0x40
        var out: [TroubleCode] = []
        for (id, payloads) in ISOTP.messages(from: reply.lines) {
            for p in payloads where p.first == positive && p.count >= 2 {
                // CAN replies carry a count byte after the service byte.
                let count = Int(p[1])
                var body = Array(p.dropFirst(2))
                if body.count != count * 2 { body = Array(p.dropFirst(1)) }
                var i = 0
                while i + 1 < body.count {
                    if let code = decode(body[i], body[i + 1]) {
                        out.append(TroubleCode(code: code, module: hex3(id), kind: kind))
                    }
                    i += 2
                }
            }
        }
        return out
    }

    public static func readAll(_ session: ELMSession) async throws -> [TroubleCode] {
        try await session.setTarget(0x7DF)
        var codes: [TroubleCode] = []
        for kind in TroubleCode.Kind.allCases {
            let reply = try await session.send(Hex.string([kind.service]), timeout: 3)
            codes += parse(reply, kind: kind)
        }
        return Array(Set(codes)).sorted()
    }

    /// Module names for the responders seen on this car.
    public static func moduleName(_ id: String) -> String {
        switch id {
        case "7E8": return "Engine"
        case "7E9": return "Transmission"
        default: return "Module \(id)"
        }
    }
}
