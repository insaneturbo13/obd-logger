import SwiftUI

// The Dynamic Island's small spots. With only this Live Activity running, the island shows
// the compact pair: an icon left of the camera, the reading right of it. When another app
// has one too (music, a timer), each gets the minimal spot, roughly 25 pt across inside,
// where the full "203 °F" was cut to "20…". So these show the number and a degree sign
// at a fixed size (text size settings don't apply up here) and shrink rather than cut.

struct IslandReading: View {
    let state: CoolantActivityAttributes.ContentState
    let stale: Bool
    var size: CGFloat = 16

    var body: some View {
        Text(state.coolantShort)
            .font(.system(size: size, weight: .semibold).width(.condensed).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // Hot: dark on a vermillion pill, so it reads by shape as well as color.
            .foregroundStyle(state.hot ? Palette.background : Palette.text)
            .padding(.horizontal, state.hot ? 3 : 0)
            .background {
                if state.hot { Capsule().fill(Palette.vermillion) }
            }
            .opacity(stale ? 0.5 : 1)
            .accessibilityLabel("Coolant \(state.coolant)\(stale ? ", no new data" : "")")
    }
}

struct IslandIcon: View {
    let state: CoolantActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        Image(systemName: stale ? "thermometer.medium.slash" : state.hot ? "thermometer.high" : "thermometer.medium")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(stale ? Palette.textSecondary : state.hot ? Palette.vermillion : Palette.skyBlue)
            .accessibilityHidden(true)
    }
}
