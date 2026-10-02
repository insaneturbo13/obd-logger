import Foundation

public struct AdapterInfo: Codable, Sendable, Equatable {
    public var identity: String = ""
    public var deviceDescription: String = ""
    public var isSTN = false
    public var protocolName: String = ""
    public var protocolNumber: String = ""
    public var batteryVoltage: Double?
    /// Responder CAN ID (hex) -> supported service 01 PIDs.
    public var supported: [String: [UInt8]] = [:]
    public var fingerprint: String = ""
    public var filterMode: String = ""

    public init() {}

    public func supportedPIDs(responder: UInt16) -> Set<UInt8> { Set(supported[hex3(responder)] ?? []) }
}

public enum AdapterSetup {
    /// Adapter settings every session relies on: echo/linefeeds/spaces off, CAN headers on
    /// (replies are parsed per responder), adaptive timing, automatic protocol.
    public static let baseCommands = ["ATE0", "ATL0", "ATS0", "ATH1", "ATAT1", "ATSP0"]

    /// Resets and configures the adapter, then asks the car which standard PIDs it supports.
    /// Throws `OBDError.noVehicleResponse` while the ignition is off.
    public static func initialize(_ session: ELMSession, readIdentity: Bool = true, calibrateFilter: Bool = true) async throws -> AdapterInfo {
        var info = AdapterInfo()
        session.resetAddressing()
        var reset = try await session.send("ATZ", timeout: 5)
        if reset.timedOut || reset.lines.isEmpty {
            // Some adapters need a moment after connecting; try once more before giving up.
            reset = try await session.send("ATZ", timeout: 5)
            guard !reset.timedOut else { throw OBDError.adapterNotResponding("ATZ") }
        }
        info.identity = reset.rawLines.last { $0.uppercased().contains("ELM") || $0.uppercased().contains("STN") } ?? reset.summary
        for cmd in baseCommands {
            let r = try await session.send(cmd, timeout: 2)
            guard r.isOK else { throw OBDError.adapterNotResponding(cmd) }
        }
        if readIdentity {
            info.deviceDescription = try await session.send("AT@1", timeout: 2).summary
            let sti = try await session.send("STI", timeout: 2)
            info.isSTN = !sti.lines.isEmpty && !sti.lines.contains("?")
        }
        info.batteryVoltage = try await readVoltage(session)

        // First request triggers the protocol search, which can take several seconds.
        let first = try await session.send("0100", timeout: 12)
        var bitmaps: [UInt16: [UInt8: [UInt8]]] = [:]
        collectBitmaps(first, base: 0x00, into: &bitmaps)
        guard !bitmaps.isEmpty else { throw OBDError.noVehicleResponse }
        var base: UInt8 = 0x20
        while base <= 0xC0 {
            // Ask for the next range only if some module says it exists.
            let wanted = bitmaps.values.contains { StandardPIDs.supported(base: base - 0x20, bitmap: $0[base - 0x20] ?? []).contains(base) }
            guard wanted else { break }
            let r = try await session.send("01" + hex2(base), timeout: 2)
            collectBitmaps(r, base: base, into: &bitmaps)
            base += 0x20
        }
        for (id, maps) in bitmaps {
            var pids = Set<UInt8>()
            for (b, m) in maps { pids.formUnion(StandardPIDs.supported(base: b, bitmap: m)) }
            info.supported[hex3(id)] = pids.sorted()
        }
        info.fingerprint = CapabilityMap.fingerprint(bitmaps: bitmaps)
        info.protocolNumber = try await session.send("ATDPN", timeout: 2).summary
        info.protocolName = try await session.send("ATDP", timeout: 2).summary
        // A second module that answers standard requests lets us test the cheaper module switching.
        if calibrateFilter, let other = bitmaps.keys.filter({ $0 != 0x7E8 && (0x7E9...0x7EF).contains($0) }).min() {
            try await session.calibrateAutoReceive(probe: other - 8)
        }
        info.filterMode = session.filterMode?.rawValue ?? "auto-detect"
        return info
    }

    static func collectBitmaps(_ reply: ELMReply, base: UInt8, into bitmaps: inout [UInt16: [UInt8: [UInt8]]]) {
        for (id, payloads) in ISOTP.messages(from: reply.lines) {
            for p in payloads where p.count >= 6 && p[0] == 0x41 && p[1] == base {
                bitmaps[id, default: [:]][base] = Array(p[2..<6])
            }
        }
    }

    /// The adapter's own measurement of its supply voltage, e.g. "14.0V".
    public static func readVoltage(_ session: ELMSession) async throws -> Double? {
        let r = try await session.send("ATRV", timeout: 2)
        let digits = r.lines.first?.filter { "0123456789.".contains($0) } ?? ""
        return Double(digits)
    }
}
