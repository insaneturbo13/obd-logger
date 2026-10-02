import Foundation
import Observation
import OBDKit
import SwiftUI

struct SettingsData: Codable, Equatable {
    var prefs = DisplayPreferences.us
    var profileID: String? = "subaru-outback-2010-25i-cvt"

    // Recording
    var autoRecord = true
    /// A reconnect within this many minutes continues the same trip.
    var mergeWindowMinutes = 3.0
    /// Save every adapter command and reply with the trip (for debugging; ~1 MB per 15 min).
    var saveTrace = true

    // Coolant (Fahrenheit, as entered)
    var coolantGuideLowF = 180.0
    var coolantGuideHighF = 212.0
    var coolantAlertF = 217.0
    var coolantAlerts = true

    // Fuel
    var fuelPricePerGallon = 3.50

    // Export
    var exportWide = true
    var exportRaw = true
    var exportStep = 0.5
    var exportAgeColumns = false
    var exportFolderBookmark: Data?
    var exportFolderName: String?

    // InfluxDB 2.x upload (token lives in the Keychain)
    var influxEnabled = false
    var influxURL = ""
    var influxOrg = ""
    var influxBucket = "car_metrics"
    var influxVehicle = "my_car"

    // Adapter
    var adapterID: String?
    var adapterName: String?
    var demoMode = false

    var overrides = PollOverrides()
    var dashboardPage = 0
}

/// User settings, saved to UserDefaults as JSON. Fields added in later versions fall back
/// to their defaults when an older saved copy is loaded.
@MainActor
@Observable
final class AppSettings {
    private(set) var data: SettingsData
    private static let key = "settings.v1"

    init() {
        data = Self.load(key: Self.key)
    }

    func update(_ change: (inout SettingsData) -> Void) {
        var copy = data
        change(&copy)
        guard copy != data else { return }
        data = copy
        if let encoded = try? JSONEncoder().encode(copy) { UserDefaults.standard.set(encoded, forKey: Self.key) }
    }

    func binding<T>(_ path: WritableKeyPath<SettingsData, T>) -> Binding<T> {
        Binding(get: { self.data[keyPath: path] }, set: { value in self.update { $0[keyPath: path] = value } })
    }

    var prefs: DisplayPreferences { data.prefs }

    var profile: VehicleProfile? { data.profileID.flatMap { BuiltInProfiles.profile(id: $0) } }

    func coolantC(_ f: Double) -> Double { (f - 32) * 5 / 9 }

    private static func load(key: String) -> SettingsData {
        guard let saved = UserDefaults.standard.data(forKey: key),
              let savedDict = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let defaults = try? JSONEncoder().encode(SettingsData()),
              var merged = try? JSONSerialization.jsonObject(with: defaults) as? [String: Any] else {
            return SettingsData()
        }
        merged.merge(savedDict) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(SettingsData.self, from: data) else { return SettingsData() }
        return settings
    }
}
