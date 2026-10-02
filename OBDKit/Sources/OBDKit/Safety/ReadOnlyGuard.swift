import Foundation

/// The only gate between the app and the car. Every command the session sends passes
/// through `check`, which accepts adapter setup commands and OBD *read* requests and
/// rejects everything else: no clearing codes, no writes, no routines, no resets.
///
/// Anything that changes car state must get its own explicit, user-confirmed path;
/// it must never be added to these lists.
public enum ReadOnlyGuard {
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let command: String
        public let reason: String
        public var description: String { "refused \(command.debugDescription): \(reason)" }
    }

    /// Request service -> positive reply service.
    public static let readServices: [UInt8: UInt8] = [
        0x01: 0x41, // current data
        0x03: 0x43, // stored trouble codes
        0x07: 0x47, // pending trouble codes
        0x0A: 0x4A, // permanent trouble codes
        0x22: 0x62, // read data by identifier
        0xA8: 0xE8, // Subaru SSM read memory address
    ]

    /// Adapter commands accepted exactly as written.
    static let atExact: Set<String> = [
        "ATZ", "ATD", "ATE0", "ATL0", "ATS0", "ATH1", "ATAT0", "ATAT1", "ATAT2",
        "ATSP0", "ATDP", "ATDPN", "ATI", "AT@1", "ATRV", "ATAR", "ATCAF1", "STI", "STDI",
    ]

    /// Adapter commands followed by a hex argument.
    static let atWithHexArg = ["ATCRA", "ATSH", "ATST", "ATCF", "ATCM"]

    /// Read-by-identifier range that holds module identification, including the VIN. Never read.
    public static let privateIdentifiers: ClosedRange<UInt16> = 0xF180...0xF19F

    public static func check(_ command: String) throws {
        let c = command.uppercased()
        func refuse(_ reason: String) -> Refusal { Refusal(command: command, reason: reason) }

        // A bare CR makes an ELM327 repeat the previous command.
        guard !c.isEmpty, !c.contains(" "), !c.contains("\r"), !c.contains("\n") else {
            throw refuse("empty or spaced command")
        }
        if atExact.contains(c) { return }
        for prefix in atWithHexArg where c.hasPrefix(prefix) {
            let arg = c.dropFirst(prefix.count)
            if Hex.isHex(arg) { return }
        }
        if c.hasPrefix("AT") || c.hasPrefix("ST") { throw refuse("adapter command not on the allow list") }
        guard c.count >= 2, Hex.isHex(c), let bytes = Hex.bytes(c.count % 2 == 0 ? c : String(c.dropLast())) else {
            throw refuse("not a hex request")
        }
        let service = bytes[0]
        guard readServices[service] != nil else { throw refuse("service \(hex2(service)) is not a read service") }

        switch service {
        case 0xA8:
            // A8 00 AAAAAA: single read of one 3-byte address. Anything else is not a plain read.
            guard bytes.count == 5, bytes[1] == 0x00 else { throw refuse("malformed SSM read") }
        case 0x22:
            guard bytes.count >= 3, (bytes.count - 1) % 2 == 0 else { throw refuse("malformed identifier read") }
            var i = 1
            while i + 1 < bytes.count {
                let did = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                if privateIdentifiers.contains(did) { throw refuse("identifier \(hex2(bytes[i]))\(hex2(bytes[i + 1])) holds module identification") }
                i += 2
            }
        case 0x03, 0x07, 0x0A:
            guard bytes.count == 1 else { throw refuse("trouble-code reads take no arguments") }
        default:
            break
        }
    }
}
