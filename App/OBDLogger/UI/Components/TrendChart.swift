import Charts
import OBDKit
import SwiftUI

struct TrendSeries: Identifiable {
    let id: SignalID
    let name: String
    let color: Color
    let points: [(Date, Double)]
}

/// Line chart of recent values. Lines break where readings stopped for longer than
/// `gap` seconds, so a stall shows as a hole rather than a straight line across it.
struct TrendChart: View {
    let series: [TrendSeries]
    var unit: String
    var window: TimeInterval = 20 * 60
    /// Fixed time span (e.g. a whole trip). nil = the last `window` seconds.
    var xDomain: ClosedRange<Date>? = nil
    var gap: TimeInterval = 15
    var height: CGFloat = 220

    private struct Point: Identifiable {
        let id: Int
        let series: String
        let segment: String
        let time: Date
        let value: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        var n = 0
        for s in series {
            var segment = 0
            var previous: Date?
            for (t, v) in downsample(s.points, max: 400) {
                if let p = previous, t.timeIntervalSince(p) > gap { segment += 1 }
                previous = t
                out.append(Point(id: n, series: s.name, segment: "\(s.name)#\(segment)", time: t, value: v))
                n += 1
            }
        }
        return out
    }

    var body: some View {
        let pts = points
        Chart(pts) { p in
            LineMark(x: .value("Time", p.time), y: .value(unit, p.value), series: .value("Segment", p.segment))
                .foregroundStyle(by: .value("Signal", p.series))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartXScale(domain: xDomain ?? Date().addingTimeInterval(-window)...Date())
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel(unit)
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel().foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(height: height)
        .overlay {
            if pts.isEmpty {
                Text("No data yet").font(.callout).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func downsample(_ points: [(Date, Double)], max: Int) -> [(Date, Double)] {
        guard points.count > max else { return points }
        let stride = Double(points.count) / Double(max)
        return (0..<max).map { points[Int(Double($0) * stride)] } + [points[points.count - 1]]
    }
}
