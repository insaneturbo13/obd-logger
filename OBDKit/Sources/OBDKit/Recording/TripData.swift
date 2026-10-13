import Foundation

public struct TimedValue: Sendable, Equatable {
    public let time: Date
    public let value: Double
    public init(_ time: Date, _ value: Double) {
        self.time = time
        self.value = value
    }
}

public struct TripEvent: Sendable, Equatable {
    public let time: Date
    public let kind: String
    public let detail: String
}

/// A recorded trip read back from disk.
public struct TripData: Sendable {
    public var meta: TripMeta
    public var series: [SignalID: [TimedValue]]
    public var events: [TripEvent]
    /// Readings left out on loading because their timestamps can't be right (see `load`).
    public var discardedReadings = 0

    public var start: Date { series.values.compactMap { $0.first?.time }.min() ?? meta.startedAt }
    public var end: Date { series.values.compactMap { $0.last?.time }.max() ?? meta.endedAt ?? meta.startedAt }

    public init(meta: TripMeta, series: [SignalID: [TimedValue]], events: [TripEvent] = []) {
        self.meta = meta
        self.series = series
        self.events = events
    }

    public static func load(_ dir: URL) throws -> TripData {
        let meta = try TripFiles.readMeta(dir)
        var series: [SignalID: [TimedValue]] = [:]
        // A reading can't come from long before the trip started or from after its file was
        // last written. Such a timestamp is a sensor clock gone wrong, and keeping it would
        // stretch the trip (and every export that walks it) by hours.
        let samplesURL = dir.appendingPathComponent(TripFiles.samples)
        let written = (try? FileManager.default.attributesOfItem(atPath: samplesURL.path))?[.modificationDate] as? Date
        let earliest = meta.startedAt.addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        let latest = (written ?? Date()).addingTimeInterval(300).timeIntervalSince1970 * 1000
        var discarded = 0
        for file in [TripFiles.samples, TripFiles.vehicleMotion] {
            let text = (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? ""
            // A line cut short by a crash simply fails to parse and is skipped.
            for line in text.split(separator: "\n").dropFirst() {
                let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let ms = Int64(parts[0]), let v = Double(parts[2]) else { continue }
                guard Double(ms) >= earliest && Double(ms) <= latest else {
                    discarded += 1
                    continue
                }
                series[SignalID(String(parts[1])), default: []].append(TimedValue(Date(timeIntervalSince1970: Double(ms) / 1000), v))
            }
        }
        for k in series.keys { series[k]!.sort { $0.time < $1.time } }
        var events: [TripEvent] = []
        let ev = (try? String(contentsOf: dir.appendingPathComponent(TripFiles.events), encoding: .utf8)) ?? ""
        for line in ev.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let ms = Int64(parts[0]) else { continue }
            events.append(TripEvent(time: Date(timeIntervalSince1970: Double(ms) / 1000), kind: String(parts[1]),
                                    detail: parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\""))))
        }
        var trip = TripData(meta: meta, series: series, events: events)
        trip.discardedReadings = discarded
        return trip
    }

    public func max(_ id: SignalID) -> Double? { series[id]?.map(\.value).max() }
    public func last(_ id: SignalID) -> Double? { series[id]?.last?.value }

    /// Integral of a rate signal over time (value per hour), skipping gaps longer than `maxGap` seconds.
    public func integrate(_ id: SignalID, maxGap: TimeInterval = 5) -> Double {
        guard let s = series[id], s.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<s.count {
            let dt = s[i].time.timeIntervalSince(s[i - 1].time)
            if dt > 0 && dt <= maxGap { total += (s[i].value + s[i - 1].value) / 2 * dt / 3600 }
        }
        return total
    }

    /// Longest stretch (seconds) with no new value for `id` while the trip was recording other values.
    public func longestGap(_ id: SignalID) -> TimeInterval {
        guard let s = series[id], s.count > 1 else { return 0 }
        var longest = 0.0
        for i in 1..<s.count { longest = Swift.max(longest, s[i].time.timeIntervalSince(s[i - 1].time)) }
        return longest
    }

    public func summarize() -> TripSummary {
        let fuel = integrate(DerivedSignals.fuelRate)
        let km = integrate("speed")
        return TripSummary(
            duration: end.timeIntervalSince(start),
            distanceKm: km,
            fuelLiters: fuel,
            maxCoolant: max("coolant_temp"),
            maxOil: max("oil_temp"),
            maxCVT: max("cvt_fluid_temp"),
            maxSpeed: max("speed"),
            minVoltage: series["module_voltage"]?.map(\.value).min(),
            samples: series.values.reduce(0) { $0 + $1.count },
            longestRPMGap: longestGap("rpm")
        )
    }
}

public struct TripSummary: Codable, Sendable, Equatable {
    public var duration: TimeInterval
    public var distanceKm: Double
    public var fuelLiters: Double
    public var maxCoolant: Double?
    public var maxOil: Double?
    public var maxCVT: Double?
    public var maxSpeed: Double?
    public var minVoltage: Double?
    public var samples: Int
    /// Longest wait between engine-speed readings: a quick check that polling never stalled.
    public var longestRPMGap: TimeInterval

    public var economyKmPerLiter: Double? { fuelLiters > 0.05 ? distanceKm / fuelLiters : nil }
}
