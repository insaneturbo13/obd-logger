import SwiftUI

/// 270° arc from bottom-left over the top to bottom-right. `start`/`end` are 0...1 along it.
struct GaugeArc: Shape {
    var start: Double
    var end: Double
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set {
            start = newValue.first
            end = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2 - inset
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .degrees(135 + 270 * start), endAngle: .degrees(135 + 270 * end), clockwise: false)
        return p
    }
}

struct GaugeNeedle: Shape {
    var position: Double

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a = Angle.degrees(135 + 270 * position).radians
        let tip = CGPoint(x: c.x + cos(a) * r * 0.92, y: c.y + sin(a) * r * 0.92)
        let base = CGPoint(x: c.x + cos(a) * r * 0.62, y: c.y + sin(a) * r * 0.62)
        var p = Path()
        p.move(to: base)
        p.addLine(to: tip)
        return p
    }
}

/// Round gauge: track, optional guide band (green) and watch mark (vermillion tick + label),
/// value as a needle *and* as large text with its unit.
struct RadialGauge: View {
    let reading: SignalReading
    var title: String? = nil
    /// Display-unit band drawn under the track (e.g. a coolant guide).
    var band: ClosedRange<Double>? = nil
    /// Display-unit watch point.
    var mark: Double? = nil
    var hot = false
    var tint: Color = Palette.skyBlue

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let line = max(6, size * 0.06)
                ZStack {
                    GaugeArc(start: 0, end: 1, inset: line / 2).stroke(Palette.surfaceRaised, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    if let band, let lo = reading.position(band.lowerBound), let hi = reading.position(band.upperBound) {
                        GaugeArc(start: lo, end: hi, inset: line / 2).stroke(Palette.green.opacity(0.7), style: StrokeStyle(lineWidth: line))
                    }
                    if let mark, let m = reading.position(mark) {
                        GaugeArc(start: m - 0.004, end: m + 0.004, inset: line / 2)
                            .stroke(Palette.vermillion, style: StrokeStyle(lineWidth: line * 1.6))
                    }
                    if let f = reading.fraction {
                        // Only the needle moves smoothly between readings; numbers change instantly.
                        GaugeArc(start: 0, end: f, inset: line * 1.6).stroke(hot ? Palette.vermillion : tint, style: StrokeStyle(lineWidth: line * 0.35, lineCap: .round))
                            .animation(.easeOut(duration: 0.35), value: f)
                        GaugeNeedle(position: f).stroke(hot ? Palette.vermillion : Palette.text, style: StrokeStyle(lineWidth: max(3, line * 0.45), lineCap: .round))
                            .animation(.easeOut(duration: 0.35), value: f)
                    }
                    VStack(spacing: 0) {
                        Text(reading.text)
                            .font(.system(size: size * 0.24, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(hot ? Palette.vermillion : Palette.text)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(reading.unit).font(.system(size: max(11, size * 0.085))).foregroundStyle(Palette.textSecondary)
                        if hot {
                            Text("HOT").font(.system(size: max(10, size * 0.075), weight: .bold))
                                .padding(.horizontal, 6).background(Palette.vermillion, in: Capsule()).foregroundStyle(Palette.background)
                        }
                    }
                    .offset(y: size * 0.06)
                    if let span = reading.span {
                        HStack {
                            Text(DisplayValueText.short(span.lowerBound))
                            Spacer()
                            Text(DisplayValueText.short(span.upperBound))
                        }
                        .font(.system(size: max(9, size * 0.06)).monospacedDigit())
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, size * 0.16)
                        .offset(y: size * 0.4)
                    }
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            GaugeCaption(title: title ?? reading.name, reading: reading)
        }
        .opacity(reading.stale ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title ?? reading.name) \(reading.text) \(reading.unit)\(hot ? ", hot" : "")\(reading.stale ? ", stale" : "")")
    }
}

enum DisplayValueText {
    static func short(_ v: Double) -> String {
        abs(v) >= 1000 ? String(format: "%.0fk", v / 1000) : String(format: v == v.rounded() ? "%.0f" : "%.1f", v)
    }
}

struct GaugeCaption: View {
    let title: String
    let reading: SignalReading

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
            if let status = reading.status {
                Text(status).font(.caption2).foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 4).overlay(Capsule().stroke(Palette.hairline))
            }
            if reading.stale, let age = reading.age {
                Label(age.shortAge, systemImage: "clock").labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(Palette.yellow)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Palette.textSecondary)
    }
}

/// Horizontal bar. Signed spans (e.g. fuel trims) fill from zero in either direction,
/// with the sign shown in the number as well as the bar's side.
struct BarGauge: View {
    let reading: SignalReading
    var title: String? = nil
    var tint: Color = Palette.orange
    var negativeTint: Color = Palette.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title ?? reading.name).font(.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(1)
                Spacer()
                Text(reading.text).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Palette.text)
                Text(reading.unit).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let zero = reading.position(0) ?? 0
                let f = reading.fraction ?? zero
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceRaised)
                    Rectangle().fill(f >= zero ? tint : negativeTint)
                        .frame(width: abs(f - zero) * w)
                        .offset(x: min(f, zero) * w)
                    if zero > 0 && zero < 1 {
                        Rectangle().fill(Palette.textTertiary).frame(width: 2).offset(x: zero * w - 1)
                    }
                }
                .clipShape(Capsule())
                .animation(.easeOut(duration: 0.3), value: f)
            }
            .frame(height: 10)
            if reading.stale, let age = reading.age {
                Text("no new value for \(age.shortAge)").font(.caption2).foregroundStyle(Palette.yellow)
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .opacity(reading.stale ? 0.5 : 1)
    }
}

/// Number with unit and caption, for values better read exactly than placed on a scale.
struct ValueTile: View {
    let reading: SignalReading
    var title: String? = nil
    var accent: Color? = nil
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GaugeCaption(title: title ?? reading.name, reading: reading)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.text)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent ?? Palette.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(reading.unit).font(.callout).foregroundStyle(Palette.textSecondary)
            }
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .opacity(reading.stale ? 0.5 : 1)
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline).foregroundStyle(Palette.textSecondary)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
