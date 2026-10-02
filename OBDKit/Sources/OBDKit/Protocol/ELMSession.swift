import Foundation

/// A byte pipe to an ELM327-style adapter (Bluetooth LE on iOS, a simulator in tests).
public protocol OBDTransport: AnyObject, Sendable {
    /// Called with every chunk of bytes from the adapter, in order. Set once, before writing.
    func setReceiveHandler(_ handler: @escaping @Sendable ([UInt8]) -> Void)
    func write(_ bytes: [UInt8]) async throws
    var isConnected: Bool { get }
}

public enum OBDError: Error, Equatable, CustomStringConvertible {
    case disconnected
    case adapterNotResponding(String)
    case noVehicleResponse
    case filterLost(String)
    case busy

    public var description: String {
        switch self {
        case .disconnected: return "adapter disconnected"
        case .adapterNotResponding(let c): return "adapter didn't answer \(c)"
        case .noVehicleResponse: return "no reply from the car"
        case .filterLost(let h): return "adapter stopped accepting its receive filter for \(h)"
        case .busy: return "another command is in flight"
        }
    }
}

/// One line of the TX/RX trace, for debugging and for replaying real sessions in tests.
public struct TraceLine: Sendable {
    public enum Kind: String, Sendable { case tx = "TX", rx = "RX", note = "##" }
    public let time: Date
    public let kind: Kind
    public let text: String
    public let elapsed: Double?
    public let timedOut: Bool

    public var formatted: String {
        let t = String(format: "%.3f", time.timeIntervalSince1970)
        switch kind {
        case .tx: return "\(t) TX \(text)"
        case .note: return "\(t) ## \(text)"
        case .rx:
            let ms = String(format: "%.1f", (elapsed ?? 0) * 1000)
            return "\(t) RX \(ms)ms\(timedOut ? " TIMEOUT" : "") \(text.debugDescription)"
        }
    }
}

/// Request/response conversation with the adapter: one command at a time, each answered by
/// a `>` prompt. Not re-entrant; the poller is its only caller.
public final class ELMSession: @unchecked Sendable {
    public enum FilterMode: String, Sendable {
        /// ATCRA per module: proven on the Veepeak, costs a second command per module change.
        case cra = "CRA"
        case cfcm = "CF/CM"
        /// The adapter's automatic receive filter follows the header, so ATSH alone changes module.
        case autoReceive = "AR"
        case none
    }

    public let transport: OBDTransport
    public var trace: (@Sendable (TraceLine) -> Void)?

    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var promptSeen = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var waitID = 0
    private var timeoutTask: Task<Void, Never>?
    private var inFlight = false

    /// Header the adapter currently sends with (e.g. 0x7E0), or nil if unknown.
    public private(set) var currentHeader: UInt16?
    public private(set) var filterMode: FilterMode?
    public private(set) var commandsSent = 0

    public init(transport: OBDTransport) {
        self.transport = transport
        transport.setReceiveHandler { [weak self] bytes in self?.feed(bytes) }
    }

    func feed(_ bytes: [UInt8]) {
        let resume: CheckedContinuation<Bool, Never>? = lock.locked {
            buffer.append(contentsOf: bytes)
            guard bytes.contains(0x3E) else { return nil } // '>'
            promptSeen = true
            let w = waiter
            waiter = nil
            return w
        }
        resume?.resume(returning: true)
    }

    /// Sends one command and waits for the prompt. Every command passes the read-only guard.
    public func send(_ command: String, timeout: Double = 3.0) async throws -> ELMReply {
        try ReadOnlyGuard.check(command)
        let busy: Bool = lock.locked {
            if inFlight { return true }
            inFlight = true
            buffer.removeAll(keepingCapacity: true)
            promptSeen = false
            return false
        }
        if busy { throw OBDError.busy }
        defer { lock.locked { inFlight = false } }

        guard transport.isConnected else { throw OBDError.disconnected }
        trace?(TraceLine(time: Date(), kind: .tx, text: command, elapsed: nil, timedOut: false))
        let start = ContinuousClock.now
        do {
            try await transport.write(Array((command + "\r").utf8))
        } catch {
            throw OBDError.disconnected
        }
        let gotPrompt = await waitForPrompt(timeout: timeout)
        let elapsed = start.duration(to: .now).seconds
        let text: String = lock.locked {
            let raw = String(decoding: buffer, as: UTF8.self)
            return raw.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        }
        commandsSent += 1
        trace?(TraceLine(time: Date(), kind: .rx, text: text, elapsed: elapsed, timedOut: !gotPrompt))
        if !gotPrompt {
            if !transport.isConnected { throw OBDError.disconnected }
            await drain()
        }
        return ELMReply(command: command, text: text, elapsed: elapsed, timedOut: !gotPrompt)
    }

    public func note(_ text: String) {
        trace?(TraceLine(time: Date(), kind: .note, text: text, elapsed: nil, timedOut: false))
    }

    private func waitForPrompt(timeout: Double) async -> Bool {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let id: Int? = lock.locked {
                if promptSeen { return nil }
                waitID += 1
                waiter = cont
                return waitID
            }
            guard let id else {
                cont.resume(returning: true)
                return
            }
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.timeoutFired(id)
            }
            lock.locked { timeoutTask = task }
        }
        lock.locked {
            timeoutTask?.cancel()
            timeoutTask = nil
        }
        return result
    }

    private func timeoutFired(_ id: Int) {
        let w: CheckedContinuation<Bool, Never>? = lock.locked {
            guard id == waitID, let w = waiter else { return nil }
            waiter = nil
            return w
        }
        w?.resume(returning: false)
    }

    /// After a timeout, wait for late bytes so they can't be mistaken for the next reply.
    private func drain(quiet: Double = 0.4, limit: Double = 3.0) async {
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(limit * 1000)))
        while ContinuousClock.now < end {
            let n = lock.locked { buffer.count }
            try? await Task.sleep(nanoseconds: UInt64(quiet * 1_000_000_000))
            if lock.locked({ buffer.count }) == n { break }
        }
        lock.locked {
            buffer.removeAll()
            promptSeen = false
        }
    }

    // MARK: module addressing

    /// Address one module (or 0x7DF broadcast) and accept only its replies.
    public func setTarget(_ header: UInt16) async throws {
        guard header != currentHeader else { return }
        currentHeader = nil
        guard (try await send("ATSH\(hex3(header))")).isOK else { throw OBDError.adapterNotResponding("ATSH") }
        if filterMode == .autoReceive {
            // ATAR stays in effect; the reply address follows the header.
        } else if header == 0x7DF {
            if filterMode == .cfcm {
                _ = try await send("ATCF7E8")
                _ = try await send("ATCM7F0")
            } else {
                _ = try await send("ATAR")
            }
        } else {
            try await receiveOnly(header + 8)
        }
        currentHeader = header
    }

    private func receiveOnly(_ id: UInt16) async throws {
        let resp = hex3(id)
        func cra() async throws -> Bool { try await send("ATCRA\(resp)").isOK }
        func cfcm() async throws -> Bool {
            let a = try await send("ATCF\(resp)")
            let b = try await send("ATCM7FF")
            return a.isOK && b.isOK
        }
        switch filterMode {
        case nil:
            // First use: find out which filter style this adapter supports.
            if try await cra() { filterMode = .cra }
            else if try await cfcm() { filterMode = .cfcm }
            else {
                filterMode = FilterMode.none
                note("adapter accepts no receive filter; replies are filtered by CAN ID in software")
            }
        case .cra?:
            if !(try await cra()), !(try await cra()) { throw OBDError.filterLost(resp) }
        case .cfcm?:
            if !(try await cfcm()), !(try await cfcm()) { throw OBDError.filterLost(resp) }
        case .none?, .autoReceive?:
            break
        }
    }

    /// Checks whether the automatic receive filter follows the header (asks `probe`, e.g. the
    /// transmission computer, and the engine computer for their supported PIDs). If it does,
    /// changing module costs one command instead of two.
    @discardableResult
    public func calibrateAutoReceive(probe: UInt16, home: UInt16 = 0x7E0) async throws -> Bool {
        currentHeader = nil
        func answers(_ header: UInt16) async throws -> Bool {
            guard try await send("ATSH\(hex3(header))").isOK else { return false }
            let r = try await send("0100", timeout: 2)
            return ReplyClassifier.classify(r, request: "0100", expectFrom: header + 8).status == .answers
        }
        guard try await send("ATAR").isOK else { return false }
        if try await answers(probe), try await answers(home) {
            filterMode = .autoReceive
            currentHeader = home
            note("receive filter: automatic (follows ATSH)")
            return true
        }
        filterMode = nil
        currentHeader = nil
        note("receive filter: explicit per module")
        return false
    }

    /// Forget addressing state, e.g. after the adapter was reset.
    public func resetAddressing() {
        currentHeader = nil
        filterMode = nil
    }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
