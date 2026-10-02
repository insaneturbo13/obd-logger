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

/// Launch arguments for automated screenshots (debug builds only):
/// `-demo` forces demo mode, `-demoStart <s>` starts the simulated drive that many seconds in,
/// `-tab <n>` and `-page <n>` pick the tab and dashboard page.
struct LaunchOptions {
    var demo = false
    var demoStart: Double = 0
    var tab: Int?
    var page: Int?

    static let current: LaunchOptions = {
        var o = LaunchOptions()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        o.demo = args.contains("-demo")
        o.demoStart = value("-demoStart").flatMap(Double.init) ?? 0
        o.tab = value("-tab").flatMap(Int.init)
        o.page = value("-page").flatMap(Int.init)
        #endif
        return o
    }()
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let model = AppModel.shared
        let options = LaunchOptions.current
        if options.demo { model.settings.update { $0.demoMode = true } }
        if let page = options.page { model.settings.update { $0.dashboardPage = page } }
        model.engine.demoStart = options.demoStart
        model.engine.start()
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
    @State private var tab = LaunchOptions.current.tab ?? 0

    var body: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }.tag(0)
            TripsView()
                .tabItem { Label("Trips", systemImage: "road.lanes") }.tag(1)
            SensorsView()
                .tabItem { Label("Sensors", systemImage: "sensor") }.tag(2)
            CodesView()
                .tabItem { Label("Codes", systemImage: "stethoscope") }.tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
        .background(Palette.background)
        // Keep the screen on while the car is answering (the iPad is the dashboard).
        .onChange(of: engine.link) { _, link in
            UIApplication.shared.isIdleTimerDisabled = link == .polling
        }
    }
}
