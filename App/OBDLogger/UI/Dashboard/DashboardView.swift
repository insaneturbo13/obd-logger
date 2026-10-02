import OBDKit
import SwiftUI

enum DashboardPage: Int, CaseIterable, Identifiable {
    case cockpit, drivetrain, airFuel, trends
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .cockpit: return "Cockpit"
        case .drivetrain: return "Drivetrain"
        case .airFuel: return "Air & fuel"
        case .trends: return "Trends"
        }
    }
}

struct DashboardView: View {
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let page = DashboardPage(rawValue: settings.data.dashboardPage) ?? .cockpit
        VStack(spacing: 0) {
            StatusBar()
            Picker("Page", selection: settings.binding(\.dashboardPage)) {
                ForEach(DashboardPage.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            ScrollView {
                Group {
                    switch page {
                    case .cockpit: CockpitPage()
                    case .drivetrain: DrivetrainPage()
                    case .airFuel: AirFuelPage()
                    case .trends: TrendsPage()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .background(Palette.background)
    }
}

/// Connection, recording and polling health at a glance.
struct StatusBar: View {
    @Environment(LoggerEngine.self) private var engine
    @State private var noteText = ""
    @State private var askingNote = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: engine.link == .polling ? "circle.fill" : "circle.dashed")
                    .foregroundStyle(engine.link == .polling ? Palette.green : Palette.yellow)
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.link.label).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                    if let name = engine.adapterName {
                        Text(engine.isDemo ? "Demo: \(name)" : name).font(.caption2).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            if let trip = engine.activeTrip {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label("REC \(context.date.timeIntervalSince(trip.startedAt).clock)", systemImage: "record.circle")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Palette.vermillion)
                }
            }
            Spacer()
            if engine.link == .polling {
                Text(String(format: "%.1f req/s · %.0f values/s", engine.stats.requestsPerSecond, engine.stats.valuesPerSecond))
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.textTertiary)
            }
            if let v = engine.live.latest[AdapterSignals.batteryVoltage]?.value {
                Label(String(format: "%.1f V", v), systemImage: "minus.plus.batteryblock")
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.textSecondary)
            }
            if engine.live.latest[GPSSignals.latitude] != nil {
                Image(systemName: "location.fill").font(.caption).foregroundStyle(Palette.skyBlue)
                    .accessibilityLabel("GPS recording")
            }
            Menu {
                Button("Coolant top-up") { engine.addNote("coolant top-up") }
                Button("Note…") { askingNote = true }
                if engine.activeTrip != nil {
                    Button("End trip now", role: .destructive) { engine.finishTrip(reason: "ended by user") }
                }
            } label: {
                Image(systemName: "bookmark").font(.title3)
            }
            .disabled(engine.activeTrip == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Palette.surface)
        .alert("Add a note to this trip", isPresented: $askingNote) {
            TextField("What happened?", text: $noteText)
            Button("Add") {
                engine.addNote(noteText)
                noteText = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private let tileColumns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

struct CockpitPage: View {
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let s = settings.data
        let fahrenheit = s.prefs.temperature == .fahrenheit
        let coolantSpan: ClosedRange<Double> = fahrenheit ? 100...240 : 40...115
        let toDisplay: (Double) -> Double = { f in fahrenheit ? f : (f - 32) * 5 / 9 }
        let band = toDisplay(s.coolantGuideLowF)...toDisplay(s.coolantGuideHighF)
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RadialGauge(reading: engine.reading("coolant_temp", span: coolantSpan), title: "Coolant",
                            band: band, mark: toDisplay(s.coolantAlertF), hot: engine.coolantAlertActive, tint: Palette.orange)
                RadialGauge(reading: engine.reading("rpm"), title: "Engine speed")
                RadialGauge(reading: engine.reading("speed", span: s.prefs.speed == .mph ? 0...100 : 0...160), title: "Speed")
            }
            .frame(maxHeight: 300)
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ValueTile(reading: engine.reading("oil_temp"), title: "Oil")
                ValueTile(reading: engine.reading("cvt_fluid_temp"), title: "CVT fluid")
                ValueTile(reading: engine.reading("intake_air_temp"), title: "Intake air")
                ValueTile(reading: engine.reading("module_voltage", decimals: 2), title: "ECU voltage")
                ValueTile(reading: engine.reading("engine_load"), title: "Load")
                ValueTile(reading: engine.reading("maf"), title: "Airflow")
                ValueTile(reading: engine.reading("throttle"), title: "Throttle")
                ValueTile(reading: engine.reading(DerivedSignals.boost), title: "Vacuum / boost")
                ValueTile(reading: engine.reading("fuel_level", decimals: 0), title: "Fuel level")
                ValueTile(reading: engine.reading(DerivedSignals.fuelEconomy), title: "Instant economy")
                ValueTile(reading: engine.reading(DerivedSignals.distance), title: "Trip distance")
                TripFuelTile()
            }
            Card(title: "Temperatures, last 20 min") {
                TrendChart(series: trend(["coolant_temp", "oil_temp", "cvt_fluid_temp"]), unit: s.prefs.temperature == .fahrenheit ? "°F" : "°C")
            }
        }
    }

    func trend(_ ids: [SignalID]) -> [TrendSeries] { engine.trendSeries(ids) }
}

struct TripFuelTile: View {
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let used = engine.reading(DerivedSignals.fuelUsed)
        let liters = engine.live.latest[DerivedSignals.fuelUsed]?.value ?? 0
        let cost = liters * UnitConverter.gallonsPerLiter * settings.data.fuelPricePerGallon
        ValueTile(reading: used, title: "Fuel this trip", footnote: String(format: "≈ $%.2f at $%.2f/gal", cost, settings.data.fuelPricePerGallon))
    }
}

struct DrivetrainPage: View {
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RadialGauge(reading: engine.reading("rpm"), title: "Engine speed")
                RadialGauge(reading: engine.reading("turbine_speed"), title: "Turbine speed", tint: Palette.purple)
                RadialGauge(reading: engine.reading("speed", span: settings.data.prefs.speed == .mph ? 0...100 : 0...160), title: "Speed")
            }
            .frame(maxHeight: 260)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                BarGauge(reading: engine.reading("lockup_duty"), title: "Lock-up clutch duty")
                BarGauge(reading: engine.reading("transfer_duty"), title: "AWD transfer duty", tint: Palette.purple)
                BarGauge(reading: engine.reading(DerivedSignals.axleSlip), title: "Front vs rear axle", tint: Palette.orange)
            }
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ValueTile(reading: engine.reading(DerivedSignals.converterSlip), title: "Converter slip")
                ValueTile(reading: engine.reading("front_axle_speed_vdc"), title: "Front axle (ABS)")
                ValueTile(reading: engine.reading("rear_axle_speed_vdc"), title: "Rear axle (ABS)")
                ValueTile(reading: engine.reading("front_wheel_speed_tcm"), title: "Wheels (CVT)")
                ValueTile(reading: engine.reading("front_rear_rotation_ratio"), title: "Front:rear ratio")
                ValueTile(reading: engine.reading(DerivedSignals.rpmPerSpeed), title: "Engine/road speed")
                ValueTile(reading: engine.reading(GPSSignals.speed), title: "GPS speed")
                ValueTile(reading: engine.reading(DerivedSignals.acceleration), title: "Acceleration")
                ValueTile(reading: engine.reading("cvt_fluid_temp"), title: "CVT fluid")
            }
            Card(title: "Engine vs turbine speed") {
                TrendChart(series: engine.trendSeries(["rpm", "turbine_speed"]), unit: "rpm", window: 5 * 60)
            }
        }
    }
}

struct AirFuelPage: View {
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                BarGauge(reading: engine.reading("stft_b1", span: -25...25), title: "Short-term trim")
                BarGauge(reading: engine.reading("ltft_b1", span: -25...25), title: "Long-term trim")
            }
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ValueTile(reading: engine.reading("o2_b1s1_eq_ratio"), title: "Front O₂ (actual)")
                ValueTile(reading: engine.reading("commanded_eq_ratio"), title: "Commanded")
                ValueTile(reading: engine.reading("o2_b1s1_wr_current"), title: "Front O₂ current")
                ValueTile(reading: engine.reading("o2_b1s2_voltage", decimals: 2), title: "Rear O₂ voltage")
                ValueTile(reading: engine.reading("map"), title: "Manifold pressure")
                ValueTile(reading: engine.reading("baro"), title: "Barometric")
                ValueTile(reading: engine.reading("timing_advance"), title: "Timing advance")
                ValueTile(reading: engine.reading("ignition_learned_correction"), title: "Learned timing corr.")
                ValueTile(reading: engine.reading(DerivedSignals.fuelRate), title: "Fuel rate")
                ValueTile(reading: engine.reading(DerivedSignals.powerEstimate), title: "Power (rough)")
                ValueTile(reading: engine.reading("egr_commanded"), title: "EGR commanded")
                ValueTile(reading: engine.reading("egr_error"), title: "EGR error")
                ValueTile(reading: engine.reading("evap_purge"), title: "Evap purge")
                ValueTile(reading: engine.reading("evap_pressure"), title: "Evap pressure")
                ValueTile(reading: engine.reading("cat_temp_b1s1"), title: "Catalyst (calc.)")
                FuelSystemTile()
            }
            Card(title: "Fuel trims, last 10 min") {
                TrendChart(series: engine.trendSeries(["stft_b1", "ltft_b1"]), unit: "%", window: 10 * 60)
            }
        }
    }
}

struct FuelSystemTile: View {
    @Environment(LoggerEngine.self) private var engine

    var body: some View {
        let r = engine.reading("fuel_system_status")
        let code = engine.live.latest["fuel_system_status"].map { Int($0.value) }
        let text: String = {
            switch code {
            case 1: return "Open loop (warming up)"
            case 2: return "Closed loop"
            case 4: return "Open loop (load or decel)"
            case 8: return "Open loop (fault)"
            case 16: return "Closed loop (sensor fault)"
            case nil: return "–"
            default: return "Code \(code!)"
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            GaugeCaption(title: "Fuel system", reading: r)
            Text(text).font(.title3.weight(.semibold)).foregroundStyle(Palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .opacity(r.stale ? 0.5 : 1)
    }
}

struct TrendsPage: View {
    @Environment(LoggerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let p = settings.data.prefs
        VStack(spacing: 12) {
            Card(title: "Temperatures") {
                TrendChart(series: engine.trendSeries(["coolant_temp", "oil_temp", "cvt_fluid_temp", "intake_air_temp"]),
                           unit: p.temperature == .fahrenheit ? "°F" : "°C", height: 260)
            }
            Card(title: "Speed") {
                TrendChart(series: engine.trendSeries(["speed", GPSSignals.speed]), unit: p.speed == .mph ? "mph" : "km/h")
            }
            Card(title: "Engine speed") {
                TrendChart(series: engine.trendSeries(["rpm"]), unit: "rpm")
            }
            Card(title: "ECU voltage") {
                TrendChart(series: engine.trendSeries(["module_voltage"]), unit: "V", height: 160)
            }
        }
    }
}

@MainActor
extension LoggerEngine {
    func trendSeries(_ ids: [SignalID]) -> [TrendSeries] {
        let prefs = settings.prefs
        return ids.enumerated().map { i, id in
            let unit = SignalRegistry.info(id)?.unit
            let points = (live.history[id] ?? []).map { p -> (Date, Double) in
                (p.time, unit.map { UnitConverter.display(p.value, unit: $0, prefs: prefs).value } ?? p.value)
            }
            return TrendSeries(id: id, name: SignalRegistry.info(id)?.name ?? id.rawValue,
                               color: Palette.series[i % Palette.series.count], points: points)
        }
    }
}
