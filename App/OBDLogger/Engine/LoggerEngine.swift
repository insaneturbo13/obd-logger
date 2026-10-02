import Foundation
import Observation
import OBDKit
import UIKit

/// Thread-safe slot for the current recorder, so the adapter trace (written from the
/// session's thread) always lands in the active trip.
final class RecorderSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TripRecorder?
    var recorder: TripRecorder? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Owns the connection, polling and trip recording. Runs for the life of the app.
@MainActor
@Observable
final class LoggerEngine {
    enum Link: Equatable {
        case starting, bluetoothOff, unauthorized, searching, connecting, initializing, waitingForCar, polling, carOff

        var label: String {
            switch self {
            case .starting: return "Starting"
            case .bluetoothOff: return "Bluetooth is off"
            case .unauthorized: return "Bluetooth not allowed"
            case .searching: return "Looking for adapter"
            case .connecting: return "Waiting for adapter"
            case .initializing: return "Setting up adapter"
            case .waitingForCar: return "Adapter ready, ignition off"
            case .polling: return "Live"
            case .carOff: return "Car not answering"
            }
        }
    }

    private(set) var link: Link = .starting
    private(set) var adapterName: String?
    private(set) var adapterInfo: AdapterInfo?
    private(set) var stats = PollerStats()
    private(set) var plan: PollPlan?
    private(set) var capability: CapabilityMap?
    private(set) var activeTrip: TripMeta?
    private(set) var lastMessage: String?
    private(set) var coolantAlertActive = false
    private(set) var isDemo = false
    /// Seconds into the simulated drive at which demo mode starts (screenshots use a warm engine).
    @ObservationIgnored var demoStart: Double = 0

    let live = LiveData()
    let settings: AppSettings
    let trips: TripStore

    @ObservationIgnored private var ble: BLEAdapterTransport?
    @ObservationIgnored private var simulator: SimulatedAdapter?
    @ObservationIgnored private var poller: Poller?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var recorder: TripRecorder?
    private let slot = RecorderSlot()
    @ObservationIgnored private var derived = DerivedSignals()
    private let location = LocationRecorder()
    private let activity = CoolantActivityController()
    @ObservationIgnored private var tripEndTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivityPush = Date.distantPast

    init(settings: AppSettings, trips: TripStore) {
        self.settings = settings
        self.trips = trips
        location.onSamples = { [weak self] samples in self?.ingestGPS(samples) }
    }

    // MARK: connection

    func start() {
        recoverUnfinishedTrips()
        isDemo = settings.data.demoMode
        if isDemo {
            let sim = SimulatedAdapter(latency: 0.06, startAt: demoStart)
            simulator = sim
            adapterName = "Simulated car"
            begin(sim)
        } else {
            let transport = BLEAdapterTransport(rememberedID: settings.data.adapterID.flatMap(UUID.init(uuidString:)))
            transport.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            ble = transport
            transport.start()
        }
    }

    /// Tears everything down and starts again (after switching demo mode or forgetting the adapter).
    func restart() {
        finishTrip(reason: "restart")
        sessionTask?.cancel()
        sessionTask = nil
        if let poller { Task { await poller.stop() } }
        poller = nil
        ble?.stop()
        ble = nil
        simulator = nil
        live.reset()
        link = .starting
        start()
    }

    func forgetAdapter() {
        ble?.forget()
        settings.update {
            $0.adapterID = nil
            $0.adapterName = nil
        }
        restart()
    }

    private func handle(_ event: BLEAdapterTransport.Event) {
        switch event {
        case .poweredOff: link = .bluetoothOff
        case .unauthorized: link = .unauthorized
        case .searching: link = .searching
        case .connecting(let name):
            adapterName = name
            if link != .polling { link = .connecting }
        case .ready(let name, let id):
            adapterName = name
            settings.update {
                $0.adapterID = id.uuidString
                $0.adapterName = name
            }
            if let ble { begin(ble) }
        case .disconnected:
            link = .connecting
        }
    }

    private func begin(_ transport: OBDTransport) {
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in await self?.runSession(transport) }
    }

    private func runSession(_ transport: OBDTransport) async {
        let session = ELMSession(transport: transport)
        let slot = self.slot
        session.trace = { line in slot.recorder?.trace(line) }
        link = .initializing
        var info: AdapterInfo?
        while info == nil {
            if Task.isCancelled || !transport.isConnected { return }
            do {
                info = try await AdapterSetup.initialize(session)
            } catch OBDError.noVehicleResponse {
                link = .waitingForCar
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                lastMessage = "Adapter setup: \(error)"
                if !transport.isConnected { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        guard let info, !Task.isCancelled else { return }
        adapterInfo = info
        let plan = PollPlan.build(supported: info.supportedPIDs(responder: 0x7E8), profile: settings.profile,
                                  overrides: settings.data.overrides)
        self.plan = plan
        let cap = trips.loadCapability(fingerprint: info.fingerprint)
        capability = cap
        let poller = Poller(session: session, plan: plan, capability: cap)
        self.poller = poller
        link = .polling
        let run = Task { await poller.run() }
        for await event in poller.events {
            handle(event)
        }
        await run.value
        if self.poller === poller { self.poller = nil }
    }

    private func handle(_ event: PollerEvent) {
        switch event {
        case .samples(let samples):
            ingest(samples)
        case .vehicle(.online):
            link = .polling
            tripEndTask?.cancel()
            tripEndTask = nil
            recorder?.event("car_online")
        case .vehicle(.offline):
            link = .carOff
            recorder?.event("car_offline")
            scheduleTripEnd(after: 30, reason: "ignition off")
        case .stats(let s):
            stats = s
        case .capability(let map):
            capability = map
            trips.saveCapability(map)
        case .note(let text):
            lastMessage = text
            recorder?.event("note", text)
        case .finished(let reason):
            recorder?.event("disconnected", reason)
            if link == .polling || link == .carOff { link = isDemo ? .starting : .connecting }
            // A reconnect within the merge window resumes this trip.
            finishTrip(reason: reason)
        }
    }

    // MARK: samples

    private func ingest(_ samples: [Sample]) {
        if recorder == nil && settings.data.autoRecord && link != .carOff { startTrip() }
        var all = samples
        for s in samples { all += derived.ingest(s) }
        recorder?.record(all)
        live.ingest(all)
        checkCoolant(samples)
        pushActivityIfDue()
    }

    private func ingestGPS(_ samples: [Sample]) {
        guard recorder != nil else { return }
        recorder?.record(samples)
        live.ingest(samples)
    }

    private func checkCoolant(_ samples: [Sample]) {
        guard let c = samples.last(where: { $0.signal == "coolant_temp" })?.value else { return }
        let alertC = settings.coolantC(settings.data.coolantAlertF)
        if !coolantAlertActive && c >= alertC {
            coolantAlertActive = true
            recorder?.event("coolant_alert", TripFiles.format(c))
            if settings.data.coolantAlerts {
                let shown = UnitConverter.display(c, unit: .celsius, prefs: settings.prefs).textWithUnit
                Notifier.post(id: "coolant", title: "Coolant \(shown)",
                              body: "Above your alert point of \(Int(settings.data.coolantAlertF)) °F.")
            }
            pushActivity()
        } else if coolantAlertActive && c < alertC - 1.5 {
            coolantAlertActive = false
            pushActivity()
        }
    }

    // MARK: trips

    private func startTrip() {
        let now = Date()
        tripEndTask?.cancel()
        let window = settings.data.mergeWindowMinutes * 60
        var rec: TripRecorder?
        if let last = trips.trips.first, let end = last.meta.endedAt ?? Self.lastWrite(last.directory),
           now.timeIntervalSince(end) < window, (last.meta.notes?.contains("Simulated") == true) == isDemo {
            rec = try? TripRecorder.resume(directory: last.directory, at: now, traceEnabled: settings.data.saveTrace)
            if let s = last.meta.summary { derived.resume(distanceKm: s.distanceKm, fuelLiters: s.fuelLiters) }
        }
        if rec == nil {
            derived = DerivedSignals()
            var signals: [SignalInfo] = plan.map { Array($0.signals.values) } ?? []
            signals += DerivedSignals.infos + GPSSignals.infos + AdapterSignals.infos
            var meta = TripMeta(id: TripMeta.id(for: now), startedAt: now, appVersion: Self.appVersion,
                                adapter: [adapterName, adapterInfo?.identity].compactMap { $0 }.joined(separator: ", "),
                                protocolName: adapterInfo?.protocolName, profileID: settings.data.profileID,
                                signals: signals.sorted { $0.id < $1.id })
            meta.notes = tripNotes
            rec = try? TripRecorder.start(root: trips.root, meta: meta, traceEnabled: settings.data.saveTrace)
        }
        guard let rec else {
            lastMessage = "Couldn't create the trip folder."
            return
        }
        recorder = rec
        slot.recorder = rec
        activeTrip = rec.meta
        rec.event("connected", [adapterName, adapterInfo?.identity, adapterInfo?.protocolName, adapterInfo?.filterMode]
            .compactMap { $0 }.joined(separator: "; "))
        if !isDemo {
            location.start()
            Notifier.requestAuthorization()
        }
        startActivityIfPossible()
        trips.refresh()
    }

    private var tripNotes: String? { isDemo ? "Simulated (demo mode)" : nil }

    private func scheduleTripEnd(after seconds: Double, reason: String) {
        tripEndTask?.cancel()
        tripEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishTrip(reason: reason)
        }
    }

    /// Stop recording now (also from the UI).
    func finishTrip(reason: String) {
        tripEndTask?.cancel()
        tripEndTask = nil
        guard let rec = recorder else { return }
        recorder = nil
        slot.recorder = nil
        activeTrip = nil
        coolantAlertActive = false
        location.stop()
        activity.end()
        rec.event("trip_end", reason)
        rec.finish(at: rec.lastSampleTime ?? Date())
        let dir = rec.directory
        let snapshot = settings.data
        let demo = isDemo
        Task.detached(priority: .utility) {
            guard var trip = try? TripData.load(dir) else { return }
            trip.meta.summary = trip.summarize()
            try? TripFiles.writeMeta(trip.meta, to: dir)
            await MainActor.run { [weak self] in self?.trips.refresh() }
            guard !demo else { return }
            await LoggerEngine.deliver(trip, dir: dir, settings: snapshot)
            await MainActor.run { [weak self] in self?.trips.refresh() }
        }
    }

    /// Finalizes trips cut short by the app being killed or crashing: end time, summary,
    /// export and upload, as a normal trip end would have done.
    private func recoverUnfinishedTrips() {
        let pending = trips.trips.filter { $0.meta.endedAt == nil }.map(\.directory)
        guard !pending.isEmpty else { return }
        let snapshot = settings.data
        Task.detached(priority: .utility) { [weak self] in
            for dir in pending {
                guard var trip = try? TripData.load(dir) else { continue }
                let end = trip.end
                trip.meta.endedAt = end
                if !trip.meta.segments.isEmpty { trip.meta.segments[trip.meta.segments.count - 1].end = end }
                trip.meta.summary = trip.summarize()
                let meta = trip.meta
                // Skip a trip that has meanwhile been resumed by a new connection.
                let stillIdle = await MainActor.run { self?.recorder?.directory != dir }
                guard stillIdle else { continue }
                try? TripFiles.writeMeta(meta, to: dir)
                if meta.notes?.contains("Simulated") != true {
                    await LoggerEngine.deliver(trip, dir: dir, settings: snapshot)
                }
            }
            await MainActor.run { self?.trips.refresh() }
        }
    }

    /// When a trip folder was last written (its end, if the app died before closing it).
    nonisolated static func lastWrite(_ dir: URL) -> Date? {
        let url = dir.appendingPathComponent(TripFiles.samples)
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Exports and uploads a finished trip as configured. Failures are noted in the trip.
    nonisolated static func deliver(_ trip: TripData, dir: URL, settings: SettingsData) async {
        var meta = trip.meta
        if settings.exportFolderBookmark != nil && (settings.exportWide || settings.exportRaw) {
            do {
                try Exporter.exportToFolder(trip, settings: settings)
                meta.exportedAt = Date()
            } catch {
                meta.notes = [meta.notes, "Export failed: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
            }
        }
        if settings.influxEnabled {
            do {
                try await Exporter.upload(trip, settings: settings)
                meta.uploadedAt = Date()
            } catch {
                meta.notes = [meta.notes, "Upload failed: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
            }
        }
        try? TripFiles.writeMeta(meta, to: dir)
    }

    // MARK: live activity

    func appBecameActive() {
        if recorder != nil { startActivityIfPossible() }
    }

    private func startActivityIfPossible() {
        guard UIApplication.shared.applicationState == .active, let start = activeTrip?.startedAt else { return }
        activity.start(tripStart: start, state: activityState())
    }

    private func pushActivityIfDue() {
        guard activity.isRunning, Date().timeIntervalSince(lastActivityPush) >= 5 else { return }
        pushActivity()
    }

    private func pushActivity() {
        lastActivityPush = Date()
        activity.update(activityState())
    }

    private func activityState() -> CoolantActivityAttributes.ContentState {
        let prefs = settings.prefs
        let lowF = 100.0, highF = 240.0
        let coolant = live.current("coolant_temp")
        let oil = live.current("oil_temp")
        let coolantF = coolant.map { $0.value * 9 / 5 + 32 }
        func text(_ r: LiveData.Reading?) -> String {
            r.map { UnitConverter.display($0.value, unit: .celsius, prefs: prefs).textWithUnit } ?? "–"
        }
        let stale = coolant.map { Date().timeIntervalSince($0.time) > 10 } ?? true
        return CoolantActivityAttributes.ContentState(
            coolant: text(coolant),
            coolantPosition: coolantF.map { ($0 - lowF) / (highF - lowF) } ?? 0,
            guideLow: (settings.data.coolantGuideLowF - lowF) / (highF - lowF),
            guideHigh: (settings.data.coolantGuideHighF - lowF) / (highF - lowF),
            oil: text(oil),
            status: link == .polling ? "Recording" : link.label,
            hot: coolantAlertActive,
            stale: stale)
    }

    // MARK: sensors and codes

    func setEnabled(_ key: String, _ on: Bool) {
        settings.update {
            if on {
                $0.overrides.disabled.remove(key)
                $0.overrides.enabled.insert(key)
            } else {
                $0.overrides.disabled.insert(key)
                $0.overrides.enabled.remove(key)
            }
        }
        if let poller { Task { await poller.setEnabled(key, on); self.plan = await poller.currentPlan() } }
    }

    func setPeriod(_ key: String, _ period: Double) {
        settings.update { $0.overrides.periods[key] = period }
        if let poller { Task { await poller.setPeriod(key, period); self.plan = await poller.currentPlan() } }
    }

    func reprobe(_ key: String) {
        if let poller { Task { await poller.reprobe(key) } }
    }

    var canReadCodes: Bool { poller != nil && link == .polling }

    func readCodes() async throws -> [TroubleCode] {
        guard let poller else { throw OBDError.disconnected }
        let codes = try await poller.perform { session in try await TroubleCodes.readAll(session) }
        recorder?.event("codes_read", codes.map { "\($0.code) \($0.kind.rawValue) \($0.module)" }.joined(separator: "; "))
        return codes
    }

    /// Marks a moment in the trip (e.g. a coolant top-up) for later analysis.
    func addNote(_ text: String) {
        recorder?.event("note", text)
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
