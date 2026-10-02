import OBDKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LoggerEngine.self) private var engine
    @State private var pickingFolder = false
    @State private var token = Keychain.get(Exporter.tokenAccount) ?? ""
    @State private var influxStatus: String?
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                units
                recording
                coolant
                fuel
                export
                influx
                adapter
                about
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Settings")
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result, let bookmark = try? Exporter.bookmark(for: url) {
                    settings.update {
                        $0.exportFolderBookmark = bookmark
                        $0.exportFolderName = url.lastPathComponent
                    }
                }
            }
        }
    }

    private var units: some View {
        Section("Units") {
            Picker("Temperature", selection: settings.binding(\.prefs.temperature)) {
                Text("°F").tag(DisplayPreferences.Temperature.fahrenheit)
                Text("°C").tag(DisplayPreferences.Temperature.celsius)
            }
            Picker("Speed and distance", selection: settings.binding(\.prefs.speed)) {
                Text("mph, miles").tag(DisplayPreferences.Speed.mph)
                Text("km/h, km").tag(DisplayPreferences.Speed.kmh)
            }
            Picker("Pressure", selection: settings.binding(\.prefs.pressure)) {
                Text("kPa").tag(DisplayPreferences.Pressure.kpa)
                Text("psi").tag(DisplayPreferences.Pressure.psi)
            }
            Picker("Fuel economy", selection: settings.binding(\.prefs.fuelEconomy)) {
                Text("mpg (US)").tag(DisplayPreferences.FuelEconomy.mpgUS)
                Text("L/100 km").tag(DisplayPreferences.FuelEconomy.litersPer100km)
            }
            Toggle("Show oxygen sensor ratio as air-fuel ratio", isOn: settings.binding(\.prefs.lambdaAsAFR))
        }
    }

    private var recording: some View {
        Section {
            Toggle("Record trips automatically", isOn: settings.binding(\.autoRecord))
            Stepper(value: settings.binding(\.mergeWindowMinutes), in: 0...30, step: 1) {
                Text("Continue a trip after a stop of up to \(Int(settings.data.mergeWindowMinutes)) min")
            }
            Toggle("Save adapter conversation with each trip", isOn: settings.binding(\.saveTrace))
            Picker("Vehicle profile", selection: settings.binding(\.profileID)) {
                Text("Standard sensors only").tag(String?.none)
                ForEach(BuiltInProfiles.all, id: \.id) { p in Text(p.name).tag(String?.some(p.id)) }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("A trip starts when the car answers and ends 30 s after it stops answering. The adapter conversation helps diagnose polling problems (about 1 MB per 15 minutes). Profile changes apply at the next connection.")
        }
    }

    private var coolant: some View {
        Section {
            Stepper(value: settings.binding(\.coolantGuideLowF), in: 120...230, step: 1) {
                Text("Guide band from \(Int(settings.data.coolantGuideLowF)) °F")
            }
            Stepper(value: settings.binding(\.coolantGuideHighF), in: 150...250, step: 1) {
                Text("Guide band to \(Int(settings.data.coolantGuideHighF)) °F")
            }
            Stepper(value: settings.binding(\.coolantAlertF), in: 150...260, step: 1) {
                Text("Alert at \(Int(settings.data.coolantAlertF)) °F")
            }
            Toggle("Notify me when coolant reaches the alert point", isOn: settings.binding(\.coolantAlerts))
        } header: {
            Text("Coolant")
        } footer: {
            Text("These are your own watch points, not factory limits. The alert also shows on the lock-screen Live Activity and is marked in the trip.")
        }
    }

    private var fuel: some View {
        Section("Fuel") {
            HStack {
                Text("Price per gallon")
                Spacer()
                TextField("3.50", value: settings.binding(\.fuelPricePerGallon), format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
            }
        }
    }

    private var export: some View {
        Section {
            Button(settings.data.exportFolderName.map { "Folder: \($0)" } ?? "Choose export folder…") { pickingFolder = true }
            if settings.data.exportFolderBookmark != nil {
                Button("Stop exporting to a folder", role: .destructive) {
                    settings.update {
                        $0.exportFolderBookmark = nil
                        $0.exportFolderName = nil
                    }
                }
            }
            Toggle("Table CSV (one row per half second)", isOn: settings.binding(\.exportWide))
            Toggle("Raw CSV (every reading as recorded)", isOn: settings.binding(\.exportRaw))
            Toggle("Add an age column per sensor", isOn: settings.binding(\.exportAgeColumns))
        } header: {
            Text("Export after each trip")
        } footer: {
            Text("Pick a folder in iCloud Drive, Google Drive, OneDrive or on the device; its app syncs it. In the table CSV a value is only repeated while it's fresh, so a stalled sensor shows as empty cells, never as a steady reading.")
        }
    }

    private var influx: some View {
        Section {
            Toggle("Upload to InfluxDB after each trip", isOn: settings.binding(\.influxEnabled))
            if settings.data.influxEnabled {
                TextField("Server URL (http://host:8086)", text: settings.binding(\.influxURL))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Organization", text: settings.binding(\.influxOrg))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Bucket", text: settings.binding(\.influxBucket))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Vehicle tag", text: settings.binding(\.influxVehicle))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API token", text: $token)
                    .onSubmit { Keychain.set(token, for: Exporter.tokenAccount) }
                Button("Save token and test") {
                    Keychain.set(token, for: Exporter.tokenAccount)
                    influxStatus = "Testing…"
                    let snapshot = settings.data
                    Task {
                        do {
                            try await Exporter.testConnection(settings: snapshot)
                            influxStatus = "Connected."
                        } catch {
                            influxStatus = error.localizedDescription
                        }
                    }
                }
                if let influxStatus { Text(influxStatus).font(.caption).foregroundStyle(Palette.textSecondary) }
            }
        } header: {
            Text("InfluxDB")
        } footer: {
            Text("InfluxDB 2.x line protocol, measurement \"trip\" tagged with vehicle and trip ID. The token is kept in the iOS Keychain. A server on your home network is reachable only when the iPad is on that network or a VPN.")
        }
    }

    private var adapter: some View {
        Section {
            LabeledContent("Adapter", value: settings.data.adapterName ?? "none yet")
            if let info = engine.adapterInfo {
                LabeledContent("Reports", value: info.identity)
                LabeledContent("Protocol", value: info.protocolName)
                LabeledContent("Module switching", value: info.filterMode)
            }
            Button("Forget this adapter", role: .destructive) { confirmForget = true }
                .disabled(settings.data.adapterID == nil)
            Toggle("Demo mode (simulated car)", isOn: Binding(get: { settings.data.demoMode }, set: { on in
                settings.update { $0.demoMode = on }
                engine.restart()
            }))
        } header: {
            Text("Adapter")
        } footer: {
            Text("The adapter accepts one connection at a time: close other OBD apps first. Demo mode runs a pretend car so the app can be tried without one; its trips are marked as demo and never exported.")
        }
        .confirmationDialog("Forget the adapter?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { engine.forgetAdapter() }
        } message: {
            Text("The app will look for an adapter again.")
        }
    }

    private var about: some View {
        Section {
            LabeledContent("Version", value: LoggerEngine.appVersion)
            Text("Read-only: the app only sends adapter setup commands and read requests. It can't clear codes or change anything in the car.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }
}
