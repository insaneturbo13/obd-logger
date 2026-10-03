import Foundation

/// The next command to send and the poll items it serves.
public struct PlannedRequest: Sendable, Equatable {
    public let header: UInt16
    public let command: String
    public let keys: [String]
}

/// Rate-based scheduler. Each item has a target period; the most overdue item (relative to
/// its own period) goes next. Measured on the Veepeak (2026-10-01):
///
/// - A request takes ~112 ms whether it carries one service 01 PID or six, so service 01
///   requests are always filled up to six PIDs with the next-most-due ones.
/// - Changing module costs two adapter commands (~150 ms), so the scheduler stays on the
///   current module unless another module's work is clearly more overdue.
/// - When demand exceeds what the adapter can do, every item slows by the same factor
///   instead of some starving.
public struct Scheduler: Sendable {
    struct Entry: Sendable {
        var item: PollItem
        var due: Double
        var blockedUntil: Double = -.infinity
        var lastSent: Double?
    }

    private(set) var entries: [String: Entry] = [:]
    public var maxPack = 6
    /// How much more overdue (in periods) another module's work must be before switching to it.
    public var stickiness = 0.75
    /// After a module change, keep serving that module's nearly-due items (up to this many
    /// requests) so the change pays off. Items on that module then fall due together and
    /// stay batched.
    public var maxBatch = 6
    /// ...unless something elsewhere is this many periods overdue.
    public var emergency = 2.0
    /// Items within this fraction of a period of being due count as nearly due.
    public var lookahead = 0.5
    private var batchHeader: UInt16?
    private var batchCount = 0

    public init(items: [PollItem], now: Double) {
        for item in items { entries[item.key] = Entry(item: item, due: now) }
    }

    public var keys: [String] { Array(entries.keys) }

    public func item(_ key: String) -> PollItem? { entries[key]?.item }

    public mutating func add(_ item: PollItem, now: Double) {
        if entries[item.key] == nil { entries[item.key] = Entry(item: item, due: now) }
        else { entries[item.key]!.item.period = item.period }
    }

    public mutating func remove(_ key: String) { entries[key] = nil }

    /// Changes an item's period. Its next poll moves to one new period after the last one, so
    /// an item that speeds up is read right away instead of waiting out its old period.
    public mutating func setPeriod(_ key: String, _ period: Double) {
        guard period > 0, var e = entries[key] else { return }
        e.item.period = period
        if let last = e.lastSent { e.due = last + period }
        entries[key] = e
    }

    public func period(_ key: String) -> Double? { entries[key]?.item.period }

    /// Keep an item out of the rotation until `until` (backoff for silent sensors).
    public mutating func block(_ key: String, until: Double) { entries[key]?.blockedUntil = until }

    public func isBlocked(_ key: String, now: Double) -> Bool { (entries[key]?.blockedUntil ?? -.infinity) > now }

    private struct Candidate {
        let header: UInt16
        let command: String
        let keys: [String]
        let score: Double
    }

    public mutating func next(now: Double, currentHeader: UInt16?) -> PlannedRequest? {
        var mode01ByHeader: [UInt16: [(Double, Entry)]] = [:]
        var candidates: [Candidate] = []
        for e in entries.values where e.blockedUntil <= now {
            let score = (now - e.due) / e.item.period
            switch e.item.request {
            case .mode01:
                mode01ByHeader[e.item.header, default: []].append((score, e))
            case .profile(_, let command):
                candidates.append(Candidate(header: e.item.header, command: command, keys: [e.item.key], score: score))
            }
        }
        for (header, list) in mode01ByHeader {
            // Highest score first; ties by PID so packing is deterministic.
            let pack = list.sorted { a, b in
                if a.0 != b.0 { return a.0 > b.0 }
                return a.1.item.key < b.1.item.key
            }.prefix(maxPack)
            var command = "01"
            for (_, e) in pack { if case .mode01(let pid) = e.item.request { command += hex2(pid) } }
            candidates.append(Candidate(header: header, command: command, keys: pack.map { $0.1.item.key }, score: pack.first!.0))
        }
        guard !candidates.isEmpty else { return nil }

        func better(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.keys.count != b.keys.count { return a.keys.count > b.keys.count }
            return a.command < b.command
        }
        let best = candidates.min { better($0, $1) }!
        var chosen = best
        if let currentHeader, best.header != currentHeader,
           let local = candidates.filter({ $0.header == currentHeader }).min(by: { better($0, $1) }),
           local.score >= -lookahead {
            let batching = batchHeader == currentHeader && batchCount < maxBatch && best.score < emergency
            if batching || best.score - local.score < stickiness { chosen = local }
        }
        if chosen.header != batchHeader {
            batchHeader = chosen.header
            batchCount = 0
        }
        batchCount += 1
        return PlannedRequest(header: chosen.header, command: chosen.command, keys: chosen.keys)
    }

    /// Call when a planned request was sent; its items become due one period later.
    public mutating func didSend(_ request: PlannedRequest, at now: Double) {
        for key in request.keys {
            guard let e = entries[key] else { continue }
            entries[key]!.due = now + e.item.period
            entries[key]!.lastSent = now
        }
    }
}
