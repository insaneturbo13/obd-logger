import Foundation

/// meta.json in each trip folder.
public struct TripMeta: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var start: Date
        public var end: Date?
    }

    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var appVersion: String
    public var adapter: String?
    public var protocolName: String?
    public var profileID: String?
    /// Each connection that wrote into this trip (reconnects within the merge window append).
    public var segments: [Segment]
    public var signals: [SignalInfo]
    public var summary: TripSummary?
    public var exportedAt: Date?
    public var uploadedAt: Date?
    public var notes: String?
    /// Set when the trip was stopped from the app. Such a trip is never resumed by a reconnect.
    public var endedByUser: Bool?
    /// Set for a trip read in from a CSV export (another device's, or Car Scanner's) rather
    /// than recorded here: the file it came from and when. Such a trip is never resumed,
    /// exported or uploaded again; its source already has it.
    public var importedFrom: String?
    public var importedAt: Date?

    public var isImported: Bool { importedFrom != nil }

    public init(id: String, startedAt: Date, appVersion: String, adapter: String? = nil, protocolName: String? = nil,
                profileID: String? = nil, signals: [SignalInfo] = []) {
        self.id = id
        self.startedAt = startedAt
        self.appVersion = appVersion
        self.adapter = adapter
        self.protocolName = protocolName
        self.profileID = profileID
        self.segments = [Segment(start: startedAt, end: nil)]
        self.signals = signals
    }

    public static func id(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }
}

public enum TripFiles {
    public static let meta = "meta.json"
    public static let samples = "samples.csv"
    public static let events = "events.csv"
    public static let trace = "trace.log"
    public static let samplesHeader = "t_ms,signal,value\n"
    public static let eventsHeader = "t_ms,kind,detail\n"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func readMeta(_ dir: URL) throws -> TripMeta {
        try decoder.decode(TripMeta.self, from: Data(contentsOf: dir.appendingPathComponent(meta)))
    }

    public static func writeMeta(_ m: TripMeta, to dir: URL) throws {
        try encoder.encode(m).write(to: dir.appendingPathComponent(meta), options: .atomic)
    }

    /// Compact number text: integers without a decimal point, others to 7 decimals, trailing zeros trimmed.
    public static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.7f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Appends samples to a trip folder as they arrive. Line-oriented CSV, flushed every second
/// and synced to disk every few seconds, so a crash or a killed app loses at most a few
/// seconds and never corrupts what is already written.
public final class TripRecorder: @unchecked Sendable {
    public let directory: URL
    public private(set) var meta: TripMeta

    private let lock = NSLock()
    private let samples: FileHandle
    private let events: FileHandle
    private var trace: FileHandle?
    private var sampleBuffer = ""
    private var eventBuffer = ""
    private var traceBuffer = ""
    private var lastFlush = Date()
    private var lastSync = Date()
    private var closed = false
    public private(set) var sampleCount = 0
    public private(set) var lastSampleTime: Date?

    public var flushInterval: TimeInterval = 1
    public var syncInterval: TimeInterval = 5

    /// Starts a new trip folder under `root`.
    public static func start(root: URL, meta: TripMeta, traceEnabled: Bool) throws -> TripRecorder {
        let dir = root.appendingPathComponent(meta.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, header) in [(TripFiles.samples, TripFiles.samplesHeader), (TripFiles.events, TripFiles.eventsHeader)] {
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data(header.utf8).write(to: url)
            }
        }
        try TripFiles.writeMeta(meta, to: dir)
        return try TripRecorder(directory: dir, meta: meta, traceEnabled: traceEnabled)
    }

    /// Reopens an existing trip to append a new segment (reconnect within the merge window).
    public static func resume(directory: URL, at date: Date, traceEnabled: Bool) throws -> TripRecorder {
        var meta = try TripFiles.readMeta(directory)
        meta.endedAt = nil
        meta.segments.append(TripMeta.Segment(start: date, end: nil))
        try TripFiles.writeMeta(meta, to: directory)
        return try TripRecorder(directory: directory, meta: meta, traceEnabled: traceEnabled)
    }

    private init(directory: URL, meta: TripMeta, traceEnabled: Bool) throws {
        self.directory = directory
        self.meta = meta
        samples = try FileHandle(forWritingTo: directory.appendingPathComponent(TripFiles.samples))
        events = try FileHandle(forWritingTo: directory.appendingPathComponent(TripFiles.events))
        try samples.seekToEnd()
        try events.seekToEnd()
        if traceEnabled {
            let url = directory.appendingPathComponent(TripFiles.trace)
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            trace = h
        }
    }

    public func record(_ batch: [Sample]) {
        guard !batch.isEmpty else { return }
        lock.locked {
            guard !closed else { return }
            for s in batch {
                sampleBuffer += "\(Int64((s.time.timeIntervalSince1970 * 1000).rounded())),\(s.signal.rawValue),\(TripFiles.format(s.value))\n"
            }
            sampleCount += batch.count
            lastSampleTime = batch.last?.time
        }
        flushIfDue()
    }

    public func event(_ kind: String, _ detail: String = "", at time: Date = Date()) {
        let clean = detail.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        lock.locked {
            guard !closed else { return }
            eventBuffer += "\(Int64((time.timeIntervalSince1970 * 1000).rounded())),\(kind),\"\(clean)\"\n"
        }
        flushIfDue()
    }

    public func trace(_ line: TraceLine) {
        lock.locked {
            guard !closed, trace != nil else { return }
            traceBuffer += line.formatted + "\n"
        }
    }

    public func updateMeta(_ change: (inout TripMeta) -> Void) {
        lock.locked { change(&meta) }
        try? TripFiles.writeMeta(lock.locked { meta }, to: directory)
    }

    private func flushIfDue() {
        let now = Date()
        if now.timeIntervalSince(lastFlush) >= flushInterval { flush(sync: now.timeIntervalSince(lastSync) >= syncInterval) }
    }

    public func flush(sync: Bool = false) {
        lock.locked {
            guard !closed else { return }
            write(&sampleBuffer, to: samples)
            write(&eventBuffer, to: events)
            if let trace { write(&traceBuffer, to: trace) }
            lastFlush = Date()
            if sync {
                try? samples.synchronize()
                try? events.synchronize()
                lastSync = lastFlush
            }
        }
    }

    private func write(_ buffer: inout String, to handle: FileHandle) {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }

    /// Closes the current segment. The trip may still be resumed later.
    public func finish(at date: Date, summary: TripSummary? = nil) {
        flush(sync: true)
        updateMeta { m in
            m.endedAt = date
            if !m.segments.isEmpty { m.segments[m.segments.count - 1].end = date }
            if let summary { m.summary = summary }
        }
        lock.locked {
            closed = true
            try? samples.close()
            try? events.close()
            try? trace?.close()
        }
    }
}
