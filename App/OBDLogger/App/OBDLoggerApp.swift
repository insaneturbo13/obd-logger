import SwiftUI
import UIKit

/// Long-lived objects, created once at launch. Bluetooth has to be set up during launch
/// (not when a view appears) so iOS can relaunch the app in the background when the
/// adapter powers up with the car.
@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings: AppSettings
    let trips: TripStore
    let engine: LoggerEngine

    private init() {
        settings = AppSettings()
        trips = TripStore()
        engine = LoggerEngine(settings: settings, trips: trips)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.engine.start()
        return true
    }
}

@main
struct OBDLoggerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model.engine)
                .environment(model.settings)
                .environment(model.trips)
                .preferredColorScheme(.dark)
                .tint(Palette.skyBlue)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.engine.appBecameActive()
                model.trips.refresh()
            }
        }
    }
}

struct RootView: View {
    @Environment(LoggerEngine.self) private var engine

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
            TripsView()
                .tabItem { Label("Trips", systemImage: "road.lanes") }
            SensorsView()
                .tabItem { Label("Sensors", systemImage: "sensor") }
            CodesView()
                .tabItem { Label("Codes", systemImage: "stethoscope") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(Palette.background)
        // Keep the screen on while the car is answering (the iPad is the dashboard).
        .onChange(of: engine.link) { _, link in
            UIApplication.shared.isIdleTimerDisabled = link == .polling
        }
    }
}
