import OBDKit
import SwiftUI
import UniformTypeIdentifiers

struct TripsView: View {
    @Environment(TripStore.self) private var store
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(TripImporter.self) private var importer
    @State private var pendingDelete: TripStore.Entry?
    @State private var picking = false
    /// One file importer serves both buttons (SwiftUI shows only one per view): files or a folder.
    @State private var pickingFolder = false

    var body: some View {
        NavigationStack {
            List {
                if importer.isRunning || importer.status != nil {
                    ImportStatusRow()
                }
                if store.trips.isEmpty {
                    Text("Trips record automatically when the car answers. They're saved on this device under Files › On My iPad › OBD Logger › Trips. Trips recorded on another device, or by Car Scanner, come in through Import at the top right.")
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(store.trips) { entry in
                    NavigationLink(value: entry.id) {
                        TripRow(entry: entry, recording: engine.activeTrip?.id == entry.id)
                    }
                    .swipeActions {
                        if engine.activeTrip?.id != entry.id {
                            Button("Delete", role: .destructive) { pendingDelete = entry }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Trips")
            .navigationDestination(for: String.self) { id in
                if let entry = store.entry(id: id) { TripDetailView(entry: entry) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { importMenu }
            }
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: pickingFolder ? [UTType.folder] : [UTType.commaSeparatedText, UTType.plainText],
                          allowsMultipleSelection: !pickingFolder) { result in
                guard case .success(let urls) = result else { return }
                if pickingFolder {
                    if let url = urls.first { importer.linkFolder(url) }
                } else {
                    Task { await importer.importFiles(urls) }
                }
            }
            .refreshable {
                store.refresh()
                await importer.checkLinkedFolder()
            }
            .confirmationDialog("Delete this trip?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let e = pendingDelete { store.delete(e) }
                    pendingDelete = nil
                }
            } message: {
                Text("Its recording is removed from this device. Copies already exported elsewhere stay.")
            }
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                pickingFolder = false
                picking = true
            } label: {
                Label("Import CSV files…", systemImage: "doc.badge.plus")
            }
            if let name = settings.data.importFolderName {
                Button {
                    Task { await importer.checkLinkedFolder() }
                } label: {
                    Label("Check \(name) now", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                Button {
                    pickingFolder = true
                    picking = true
                } label: {
                    Label("Link a folder to import from…", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .disabled(importer.isRunning)
    }
}

/// Progress and outcome of the last import, above the trip list.
struct ImportStatusRow: View {
    @Environment(TripImporter.self) private var importer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if importer.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "square.and.arrow.down").foregroundStyle(Palette.skyBlue)
            }
            VStack(alignment: .leading, spacing: 2) {
                if importer.isRunning, let p = importer.progress {
                    Text("Importing \(p.done) of \(p.total)…").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.text)
                }
                if let status = importer.status {
                    Text(status).font(.subheadline).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct TripRow: View {
    @Environment(AppSettings.self) private var settings
    let entry: TripStore.Entry
    let recording: Bool

    var body: some View {
        let m = entry.meta
        let prefs = settings.prefs
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(m.startedAt, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                    .font(.headline).foregroundStyle(Palette.text)
                if recording {
                    Label("Recording", systemImage: "record.circle").font(.caption.weight(.semibold)).foregroundStyle(Palette.vermillion)
                }
                if m.notes?.contains("Simulated") == true {
                    Text("demo").font(.caption2).padding(.horizontal, 5).overlay(Capsule().stroke(Palette.hairline))
                }
            }
            if let s = m.summary {
                HStack(spacing: 14) {
                    Text(s.duration.clock)
                    Text(UnitConverter.display(s.distanceKm, unit: .km, prefs: prefs).textWithUnit)
                    if let c = s.maxCoolant {
                        Text("coolant max \(UnitConverter.display(c, unit: .celsius, prefs: prefs).textWithUnit)")
                    }
                    if s.longestRPMGap > 10 {
                        Label("gap \(Int(s.longestRPMGap)) s", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.yellow)
                    }
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: 10) {
                if m.isImported {
                    Label(m.notes?.contains("Car Scanner") == true ? "from Car Scanner" : "imported",
                          systemImage: "square.and.arrow.down").font(.caption2)
                }
                if m.exportedAt != nil { Label("exported", systemImage: "folder").font(.caption2) }
                if m.uploadedAt != nil { Label("uploaded", systemImage: "icloud.and.arrow.up").font(.caption2) }
                if let n = m.notes, n.contains("failed") { Text(n).font(.caption2).foregroundStyle(Palette.yellow).lineLimit(2) }
            }
            .foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, 4)
    }
}

struct TripDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TripStore.self) private var store
    let entry: TripStore.Entry
    @State private var trip: TripData?
    @State private var files: Exporter.Files?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let trip {
                    summary(trip)
                    charts(trip)
                    events(trip)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(Palette.textSecondary)
                }
            }
            .padding()
        }
        .background(Palette.background)
        .navigationTitle(entry.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let wide = files?.wide { ShareLink(item: wide) { Label("Share CSV", systemImage: "tablecells") } }
                if let raw = files?.raw { ShareLink(item: raw) { Label("Share raw CSV", systemImage: "list.bullet.rectangle") } }
                Menu {
                    // An imported trip already exists where it came from; sending it back would duplicate it.
                    Button("Export to folder") { Task { await export() } }
                        .disabled(settings.data.exportFolderBookmark == nil || entry.meta.isImported)
                    Button("Upload to InfluxDB") { Task { await upload() } }
                        .disabled(!settings.data.influxEnabled || entry.meta.isImported)
                } label: { Image(systemName: "square.and.arrow.up.on.square") }
                .disabled(trip == nil || busy)
            }
        }
        .task { await load() }
    }

    /// Shows the trip as soon as it's read; the CSV files for sharing follow.
    private func load() async {
        let dir = entry.directory
        let snapshot = settings.data
        let loaded = await Task.detached(priority: .userInitiated) { try? TripData.load(dir) }.value
        trip = loaded
        guard let loaded else {
            message = "This trip couldn't be read."
            return
        }
        files = await Task.detached(priority: .utility) { try? Exporter.shareFiles(loaded, settings: snapshot) }.value
    }

    private func export() async {
        guard let trip else { return }
        busy = true
        defer { busy = false }
        do {
            try Exporter.exportToFolder(trip, settings: settings.data)
            var meta = trip.meta
            meta.exportedAt = Date()
            try? TripFiles.writeMeta(meta, to: entry.directory)
            message = "Exported to \(settings.data.exportFolderName ?? "the folder")."
            store.refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    private func upload() async {
        guard let trip else { return }
        busy = true
        defer { busy = false }
        do {
            try await Exporter.upload(trip, settings: settings.data)
            var meta = trip.meta
            meta.uploadedAt = Date()
            try? TripFiles.writeMeta(meta, to: entry.directory)
            message = "Uploaded \(trip.series.values.reduce(0) { $0 + $1.count }) readings."
            store.refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    @ViewBuilder
    private func summary(_ trip: TripData) -> some View {
        let s = trip.meta.summary ?? trip.summarize()
        let p = settings.prefs
        let fuelCost = s.fuelLiters * UnitConverter.gallonsPerLiter * settings.data.fuelPricePerGallon
        Card(title: "Summary") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                stat("Duration", s.duration.clock)
                stat("Distance", UnitConverter.display(s.distanceKm, unit: .km, prefs: p).textWithUnit)
                stat("Fuel (estimate)", UnitConverter.display(s.fuelLiters, unit: .liters, prefs: p).textWithUnit)
                stat("Cost (estimate)", String(format: "$%.2f", fuelCost))
                if let e = s.economyKmPerLiter { stat("Economy", UnitConverter.display(e, unit: .kmPerLiter, prefs: p).textWithUnit) }
                if let c = s.maxCoolant { stat("Coolant max", UnitConverter.display(c, unit: .celsius, prefs: p).textWithUnit) }
                if let o = s.maxOil { stat("Oil max", UnitConverter.display(o, unit: .celsius, prefs: p).textWithUnit) }
                if let t = s.maxCVT { stat("CVT max", UnitConverter.display(t, unit: .celsius, prefs: p).textWithUnit) }
                if let v = s.minVoltage { stat("ECU voltage min", String(format: "%.2f V", v)) }
                stat("Readings", "\(s.samples)")
                stat("Longest engine-speed gap", String(format: "%.1f s", s.longestRPMGap))
            }
            if let adapter = trip.meta.adapter { Text(adapter).font(.caption).foregroundStyle(Palette.textTertiary) }
            if trip.meta.isImported, let notes = trip.meta.notes {
                Text(notes).font(.caption).foregroundStyle(Palette.textTertiary)
            }
            if trip.discardedReadings > 0 {
                Text("\(trip.discardedReadings) readings with impossible times (long before the trip, or after it was saved) were left out.")
                    .font(.caption).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Palette.textSecondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Palette.text)
        }
    }

    @ViewBuilder
    private func charts(_ trip: TripData) -> some View {
        let p = settings.prefs
        let domain = trip.start...max(trip.end, trip.start.addingTimeInterval(1))
        let temps: [SignalID] = ["coolant_temp", "oil_temp", "cvt_fluid_temp"]
        Card(title: "Temperatures") {
            TrendChart(series: series(trip, temps), unit: p.temperature == .fahrenheit ? "°F" : "°C", xDomain: domain, height: 240)
        }
        Card(title: "Speed and engine speed") {
            TrendChart(series: series(trip, ["speed", GPSSignals.speed]), unit: p.speed == .mph ? "mph" : "km/h", xDomain: domain)
            TrendChart(series: series(trip, ["rpm"]), unit: "rpm", xDomain: domain, height: 160)
        }
        let motion: [(SignalID, String)] = [(PhoneSignals.pitch, "°"), (PhoneSignals.grade, "%"), (PhoneSignals.joltPeak, "m/s²")]
        if motion.contains(where: { trip.series[$0.0] != nil }) {
            Card(title: "Tilt, grade and bumps") {
                ForEach(motion.filter { trip.series[$0.0] != nil }, id: \.0) { item in
                    TrendChart(series: series(trip, [item.0]), unit: item.1, xDomain: domain, height: 140)
                }
                if let note = trip.meta.motionCalibration {
                    Text(note).font(.caption).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private func series(_ trip: TripData, _ ids: [SignalID]) -> [TrendSeries] {
        let prefs = settings.prefs
        let infos = Exporter.infos(for: trip)
        return ids.enumerated().compactMap { i, id in
            guard let values = trip.series[id], let info = infos[id] else { return nil }
            return TrendSeries(id: id, name: info.name, color: Palette.series[i % Palette.series.count],
                               points: values.map { ($0.time, UnitConverter.display($0.value, unit: info.unit, prefs: prefs).value) })
        }
    }

    @ViewBuilder
    private func events(_ trip: TripData) -> some View {
        let shown = trip.events.filter { $0.kind != "car_online" }
        if !shown.isEmpty {
            Card(title: "Events") {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.time, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(Palette.textTertiary)
                        Text(e.kind.replacingOccurrences(of: "_", with: " ")).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                        Text(e.detail).font(.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(2)
                    }
                }
            }
        }
    }
}
