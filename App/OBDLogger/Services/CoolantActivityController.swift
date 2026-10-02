import ActivityKit
import Foundation

/// Starts, updates and ends the coolant Live Activity. iOS only allows starting one while
/// the app is in the foreground, so a trip that begins in the background gets its
/// activity the next time the app is opened.
@MainActor
final class CoolantActivityController {
    private var activity: Activity<CoolantActivityAttributes>?
    private var lastState: CoolantActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    var isRunning: Bool { activity != nil }

    func start(tripStart: Date, state: CoolantActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Clean up any left over from a previous run of the app.
        for old in Activity<CoolantActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            activity = try Activity.request(
                attributes: CoolantActivityAttributes(tripStart: tripStart),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(90)),
                pushType: nil)
            lastState = state
            lastUpdate = Date()
        } catch {
            activity = nil
        }
    }

    /// Sends an update if the text changed or every 30 s (keeps the stale date fresh).
    func update(_ state: CoolantActivityAttributes.ContentState) {
        guard let activity else { return }
        let now = Date()
        guard state != lastState || now.timeIntervalSince(lastUpdate) > 30 else { return }
        guard now.timeIntervalSince(lastUpdate) >= 2 || state.hot != lastState?.hot else { return }
        lastState = state
        lastUpdate = now
        Task { await activity.update(ActivityContent(state: state, staleDate: now.addingTimeInterval(90))) }
    }

    func end() {
        guard let activity else { return }
        let state = lastState
        self.activity = nil
        Task {
            await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) },
                               dismissalPolicy: .after(Date().addingTimeInterval(10 * 60)))
        }
    }
}
