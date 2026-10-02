import Foundation

enum Hex {
    static let digits = Set("0123456789ABCDEF")

    /// Parses an even-length string of hex digits (no spaces). Returns nil for anything else.
    static func bytes<S: StringProtocol>(_ text: S) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        bytes.map { byte in
            let s = String(byte, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    static func isHex<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { digits.contains($0) }
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}

func hex2(_ value: UInt8) -> String { Hex.string([value]) }

func hex3(_ value: UInt16) -> String {
    let s = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, 3 - s.count)) + s
}

func hex6(_ value: UInt32) -> String {
    let s = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, 6 - s.count)) + s
}

extension NSLock {
    /// Runs `body` with the lock held. Synchronous on purpose: never await inside.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
