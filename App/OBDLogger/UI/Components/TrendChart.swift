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
            // Break into segments on the readings themselves, so thinning a long trip neither
            // hides a stall nor breaks a line into dots.
            var segments: [[(Date, Double)]] = []
            var previous: Date?
            for p in s.points {
                if let prev = previous, p.0.timeIntervalSince(prev) <= gap, !segments.isEmpty {
                    segments[segments.count - 1].append(p)
                } else {
                    segments.append([p])
                }
                previous = p.0
            }
            for (i, seg) in segments.enumerated() {
                let share = Swift.max(2, 400 * seg.count / Swift.max(1, s.points.count))
                for (t, v) in thin(seg, limit: share) {
                    out.append(Point(id: n, series: s.name, segment: "\(s.name)#\(i)", time: t, value: v))
                    n += 1
                }
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

    /// Thins to about `limit` points by keeping each bucket's lowest and highest reading, in
    /// time order, so peaks such as bumps survive on a long trip.
    private func thin(_ points: [(Date, Double)], limit: Int) -> [(Date, Double)] {
        guard points.count > limit, limit >= 2 else { return points }
        let buckets = limit / 2
        let size = Double(points.count) / Double(buckets)
        var out: [(Date, Double)] = []
        out.reserveCapacity(limit)
        for b in 0..<buckets {
            let lo = Int(Double(b) * size), hi = Swift.min(points.count, Int(Double(b + 1) * size))
            guard lo < hi, let low = points[lo..<hi].min(by: { $0.1 < $1.1 }),
                  let high = points[lo..<hi].max(by: { $0.1 < $1.1 }) else { continue }
            if low.0 == high.0 { out.append(low) } else { out += low.0 < high.0 ? [low, high] : [high, low] }
        }
        return out
    }
}
