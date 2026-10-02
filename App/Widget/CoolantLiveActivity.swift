import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OBDLoggerWidgets: WidgetBundle {
    var body: some Widget {
        CoolantLiveActivity()
    }
}

struct CoolantLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CoolantActivityAttributes.self) { context in
            LockScreenView(state: context.state, start: context.attributes.tripStart)
                .activityBackgroundTint(Palette.background.opacity(0.92))
                .activitySystemActionForegroundColor(Palette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coolant").font(.caption2).foregroundStyle(Palette.textSecondary)
                        Text(context.state.coolant).font(.title2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(context.state.hot ? Palette.vermillion : Palette.text)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Oil").font(.caption2).foregroundStyle(Palette.textSecondary)
                        Text(context.state.oil).font(.title3.monospacedDigit()).foregroundStyle(Palette.text)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CoolantBar(state: context.state).frame(height: 10)
                    Text(context.state.status).font(.caption2).foregroundStyle(Palette.textSecondary)
                }
            } compactLeading: {
                Image(systemName: "thermometer.medium").foregroundStyle(context.state.hot ? Palette.vermillion : Palette.skyBlue)
            } compactTrailing: {
                Text(context.state.coolant).monospacedDigit().foregroundStyle(context.state.hot ? Palette.vermillion : Palette.text)
            } minimal: {
                Text(context.state.coolant).font(.caption2.monospacedDigit())
            }
        }
    }
}

struct LockScreenView: View {
    let state: CoolantActivityAttributes.ContentState
    let start: Date

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Coolant").font(.subheadline).foregroundStyle(Palette.textSecondary)
                    if state.hot {
                        Text("HOT").font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.vermillion, in: Capsule()).foregroundStyle(Palette.background)
                    }
                    if state.stale {
                        Text("no new data").font(.caption).foregroundStyle(Palette.yellow)
                    }
                }
                Text(state.coolant)
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(state.hot ? Palette.vermillion : Palette.text)
                    .opacity(state.stale ? 0.5 : 1)
                CoolantBar(state: state).frame(height: 10)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text("Oil \(state.oil)").font(.headline.monospacedDigit()).foregroundStyle(Palette.text)
                Text(start, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                Text(state.status).font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(16)
    }
}

/// Horizontal coolant scale: guide band in green, the reading as a marker (position carries
/// the meaning, not only color).
struct CoolantBar: View {
    let state: CoolantActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceRaised)
                Rectangle().fill(Palette.green.opacity(0.55))
                    .frame(width: max(0, (state.guideHigh - state.guideLow) * w))
                    .offset(x: state.guideLow * w)
                Capsule().fill(state.hot ? Palette.vermillion : Palette.text)
                    .frame(width: 4, height: geo.size.height + 6)
                    .offset(x: min(max(0, state.coolantPosition), 1) * w - 2)
            }
        }
    }
}
