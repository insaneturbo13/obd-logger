import OBDKit
import SwiftUI

/// Every sensor the car offers, what it's reading now, how often it actually arrives, and
/// whether it answers. Sensors can be switched off or polled faster/slower.
struct SensorsView: View {
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var search = ""

    static let periods: [Double] = [0.33, 0.5, 1, 2, 5, 10, 30, 60]

    struct Row: Identifiable {
        let id: String
        let key: String?
        let signals: [SignalInfo]
        let period: Double?
        let active: Bool
    }

    var rows: [Row] {
        guard let plan = engine.plan else { return [] }
        var bySignalKey: [String: [SignalInfo]] = [:]
        for (sid, key) in plan.itemKeyForSignal {
            if let info = plan.signals[sid] { bySignalKey[key, default: []].append(info) }
        }
        let items = plan.items.map { ($0, true) } + plan.inactive.map { ($0, false) }
        var out = items.map { item, active in
            Row(id: item.key, key: item.key, signals: (bySignalKey[item.key] ?? []).sorted { $0.name < $1.name },
                period: item.period, active: active)
        }
        let extra = DerivedSignals.infos + GPSSignals.infos + AdapterSignals.infos
        out += extra.map { Row(id: $0.id.rawValue, key: nil, signals: [$0], period: nil, active: true) }
        if !search.isEmpty {
            out = out.filter { r in r.signals.contains { $0.name.localizedCaseInsensitiveContains(search) || $0.id.rawValue.contains(search.lowercased()) } }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if engine.plan == nil {
                    Text("Sensors appear once the adapter is connected and the car answers.")
                        .foregroundStyle(Palette.textSecondary)
                }
                let all = rows
                ForEach(SignalCategory.allCases, id: \.self) { category in
                    let inCategory = all.filter { ($0.signals.first?.category ?? .status) == category }
                    if !inCategory.isEmpty {
                        Section(categoryTitle(category)) {
                            ForEach(inCategory) { row in SensorRow(row: row) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .searchable(text: $search)
            .navigationTitle("Sensors")
        }
    }

    func categoryTitle(_ c: SignalCategory) -> String {
        switch c {
        case .engine: return "Engine"
        case .temperatures: return "Temperatures"
        case .airFuel: return "Air and fuel"
        case .throttle: return "Throttle and pedal"
        case .drivetrain: return "Drivetrain"
        case .electrical: return "Electrical"
        case .emissions: return "Emissions"
        case .fuel: return "Fuel"
        case .status: return "Status and counters"
        case .location: return "Location (iPad GPS)"
        case .derived: return "Calculated in the app"
        }
    }
}

struct SensorRow: View {
    @Environment(LoggerEngine.self) private var engine
    let row: SensorsView.Row

    var body: some View {
        let item = row.key.flatMap { engine.stats.items[$0] }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(row.signals, id: \.id) { info in
                let r = engine.reading(info.id)
                HStack(alignment: .firstTextBaseline) {
                    Text(info.name).foregroundStyle(row.active ? Palette.text : Palette.textTertiary)
                    if let status = info.status, status != "verified" {
                        Text(status).font(.caption2).foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, 4).overlay(Capsule().stroke(Palette.hairline))
                    }
                    Spacer()
                    Text(r.value == nil ? "–" : "\(r.text) \(r.unit)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(r.stale ? Palette.yellow : Palette.text)
                }
            }
            if let key = row.key {
                HStack(spacing: 10) {
                    stateLabel(item?.state, active: row.active, blocked: item?.blocked ?? false)
                    if let achieved = item?.achievedPeriod {
                        Text(achieved < 1 ? String(format: "every %.2f s", achieved) : String(format: "every %.1f s", achieved))
                    }
                    Text(key).foregroundStyle(Palette.textTertiary)
                    Spacer()
                    if item?.state == .unsupported || item?.state == .silent {
                        Button("Try again") { engine.reprobe(key) }.buttonStyle(.borderless)
                    }
                    Menu {
                        Picker("Target", selection: Binding(get: { row.period ?? 1 }, set: { engine.setPeriod(key, $0) })) {
                            ForEach(SensorsView.periods, id: \.self) { p in
                                Text(p < 1 ? String(format: "every %.2f s", p) : "every \(Int(p)) s").tag(p)
                            }
                        }
                    } label: {
                        Text(row.period.map { $0 < 1 ? String(format: "target %.2f s", $0) : "target \(Int($0)) s" } ?? "")
                    }
                    Toggle("Poll", isOn: Binding(get: { row.active }, set: { engine.setEnabled(key, $0) })).labelsHidden()
                }
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateLabel(_ state: CapabilityMap.State?, active: Bool, blocked: Bool) -> some View {
        if !active {
            Label("off", systemImage: "pause.circle")
        } else {
            switch state {
            case .active?: Label(blocked ? "backing off" : "answers", systemImage: blocked ? "hourglass" : "checkmark.circle")
            case .silent?: Label("no answer", systemImage: "questionmark.circle").foregroundStyle(Palette.yellow)
            case .unsupported?: Label("not supported", systemImage: "xmark.circle").foregroundStyle(Palette.vermillion)
            default: Label("not asked yet", systemImage: "circle.dotted")
            }
        }
    }
}
