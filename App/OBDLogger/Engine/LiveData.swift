import Foundation
import Observation
import OBDKit

/// Latest value of every signal plus recent history for charts. Samples arrive at up to
/// ~50 per second; the UI-facing copy is published at 10 Hz so SwiftUI redraws stay cheap.
@MainActor
@Observable
final class LiveData {
    struct Reading: Equatable {
        var value: Double
        var time: Date
    }

    struct Point: Identifiable, Equatable {
        let time: Date
        let value: Double
        var id: Date { time }
    }

    /// Published at 10 Hz.
    private(set) var latest: [SignalID: Reading] = [:]
    /// Advances with each publish, so staleness indicators update without new data.
    private(set) var now = Date()
    private(set) var history: [SignalID: [Point]] = [:]

    @ObservationIgnored private var pending: [SignalID: Reading] = [:]
    @ObservationIgnored private var pendingHistory: [SignalID: [Point]] = [:]
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastHistory: [SignalID: Date] = [:]

    /// Signals kept for charts, and how long.
    let historySignals: Set<SignalID> = [
        "coolant_temp", "oil_temp", "cvt_fluid_temp", "intake_air_temp", "rpm", "speed", "turbine_speed",
        "stft_b1", "ltft_b1", "module_voltage", "maf", "engine_load", "gps_speed",
    ]
    let historyWindow: TimeInterval = 20 * 60

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    /// Values as they are right now, including ones not yet published to the UI.
    func current(_ id: SignalID) -> Reading? { pending[id] ?? latest[id] }

    func ingest(_ samples: [Sample]) {
        for s in samples {
            pending[s.signal] = Reading(value: s.value, time: s.time)
            if historySignals.contains(s.signal) {
                // At most two points per second per signal is plenty for a 20-minute chart.
                if let last = lastHistory[s.signal], s.time.timeIntervalSince(last) < 0.5 { continue }
                lastHistory[s.signal] = s.time
                pendingHistory[s.signal, default: []].append(Point(time: s.time, value: s.value))
            }
        }
        dirty = true
    }

    func reset() {
        pending = [:]
        pendingHistory = [:]
        latest = [:]
        history = [:]
        lastHistory = [:]
    }

    private func publish() {
        now = Date()
        guard dirty else { return }
        dirty = false
        latest.merge(pending) { _, new in new }
        pending = [:]
        if !pendingHistory.isEmpty {
            let cutoff = now.addingTimeInterval(-historyWindow)
            for (id, points) in pendingHistory {
                var list = (history[id] ?? []) + points
                if let first = list.first, first.time < cutoff { list.removeAll { $0.time < cutoff } }
                history[id] = list
            }
            pendingHistory = [:]
        }
    }
}
