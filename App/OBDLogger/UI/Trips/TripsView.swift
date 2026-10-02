import OBDKit
import SwiftUI

struct TripsView: View {
    @Environment(TripStore.self) private var store
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var pendingDelete: TripStore.Entry?

    var body: some View {
        NavigationStack {
            List {
                if store.trips.isEmpty {
                    Text("Trips record automatically when the car answers. They're saved on this device under Files › On My iPad › OBD Logger › Trips.")
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
            .refreshable { store.refresh() }
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
                    Button("Export to folder") { Task { await export() } }
                        .disabled(settings.data.exportFolderBookmark == nil)
                    Button("Upload to InfluxDB") { Task { await upload() } }
                        .disabled(!settings.data.influxEnabled)
                } label: { Image(systemName: "square.and.arrow.up.on.square") }
                .disabled(trip == nil || busy)
            }
        }
        .task { await load() }
    }

    private func load() async {
        let dir = entry.directory
        let snapshot = settings.data
        let result = await Task.detached(priority: .userInitiated) { () -> (TripData?, Exporter.Files?) in
            guard let t = try? TripData.load(dir) else { return (nil, nil) }
            return (t, try? Exporter.shareFiles(t, settings: snapshot))
        }.value
        trip = result.0
        files = result.1
        if trip == nil { message = "This trip couldn't be read." }
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
