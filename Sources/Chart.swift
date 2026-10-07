import SwiftUI

/// Battery level across the day as a filled area.
///
/// Charging is marked by a shaded band across the plot for the stretch it
/// covers, with a bolt on it, plus the original bar on the axis underneath.
///
/// The band was a thin axis bar alone, kept off the curve so the shape of the
/// day stayed readable. That is still the risk, and it is why the band is 8%
/// green and sits BEHIND the area fill rather than over it: at that weight it
/// reads as a region of the day rather than as a second series, and the curve
/// is never obscured. The axis bar stays because the band's edges are soft and
/// the bar's are not -- one says roughly where, the other says exactly.
///
/// The x axis is always the full day, midnight to midnight, even when only part of
/// it has happened yet. Scaling it to whatever has been recorded would make every
/// day a different shape and ruin the one thing a chart like this is for -- putting
/// two days side by side.
struct BatteryChartView: View {
    let day: Date
    let points: [ChartPoint]
    /// Only the charging bolt needs it: white reads well on the band in dark
    /// mode and vanishes on it in light, where the band is 8% green on white.
    var scheme: ColorScheme = .light

    private let rightGutter: CGFloat = 36
    private let bottomGutter: CGFloat = 20     // charging bar, then the hour labels
    private let plotHeight: CGFloat = 62
    private let topPad: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in draw(ctx, size) }
            .frame(height: plotHeight + bottomGutter + topPad)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 14)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let midnight = Calendar.current.startOfDay(for: day)
        let plot = CGRect(x: 0, y: topPad, width: size.width - rightGutter, height: plotHeight)
        func x(_ t: Date) -> CGFloat {
            plot.minX + CGFloat(t.timeIntervalSince(midnight) / 86_400) * plot.width
        }
        func y(_ pct: Int) -> CGFloat {
            plot.maxY - plot.height * CGFloat(min(max(pct, 0), 100)) / 100
        }

        for pct in [0, 50, 100] {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(pct)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(pct)))
            ctx.stroke(line, with: .color(.primary.opacity(pct == 0 ? 0.16 : 0.07)), lineWidth: 0.5)
            ctx.draw(Text("\(pct)%").font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.maxX + 6, y: y(pct)), anchor: .leading)
        }

        for h in stride(from: 0, to: 24, by: 3) {
            let t = midnight.addingTimeInterval(Double(h) * 3600)
            let label = h == 0 ? "12A" : (h == 12 ? "12P" : "\(h % 12)")
            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: x(t) + 1, y: plot.maxY + 13), anchor: .leading)
        }

        // Behind the area fill, deliberately: drawn after, even at low alpha, it
        // would tint the curve it is supposed to sit under.
        let runs = chargingRuns()
        for run in runs {
            let left = x(run.0), right = max(x(run.1), x(run.0) + 2)
            ctx.fill(Path(CGRect(x: left, y: plot.minY, width: right - left, height: plot.height)),
                     with: .color(.green.opacity(0.08)))
        }

        guard points.count > 1 else { return }

        var line = Path()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: x(p.t), y: y(p.pct))
            i == 0 ? line.move(to: pt) : line.addLine(to: pt)
        }
        var area = line
        area.addLine(to: CGPoint(x: x(points.last!.t), y: plot.maxY))
        area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [.green.opacity(0.34), .green.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        ctx.stroke(line, with: .color(.green),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

        for run in runs {
            let left = x(run.0), right = x(run.1)
            let bar = CGRect(x: left, y: plot.maxY + 2.5,
                             width: max(right - left, 4), height: 3)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(.green))

            // One badge per run, centred in the band, and only where the run is
            // wide enough to hold it. A 20-minute top-up is four points across;
            // a glyph stamped on that is wider than the thing it marks and
            // lands on its neighbours, so short runs keep the bar alone.
            guard right - left >= 18 else { continue }
            let centre = CGPoint(x: (left + right) / 2, y: plot.midY)

            // Bare glyph, no disc behind it. Which means the colour has to do
            // the work on its own: white on the dark band reads cleanly, white
            // on the light one -- 8% green over white -- is invisible. So it is
            // white in dark mode and green in light, rather than one colour
            // that is only right half the time.
            ctx.draw(Text(Image(systemName: "bolt.fill"))
                        .font(.system(size: 14))
                        .foregroundStyle(scheme == .dark ? Color.white : .green),
                     at: centre, anchor: .center)
        }
    }

    /// Contiguous stretches on AC, as (start, end) instants. A point stands for the
    /// 15 minutes after it, so the end is extended by one slot or a short charge
    /// collapses to a zero-width mark.
    private func chargingRuns() -> [(Date, Date)] {
        var runs: [(Date, Date)] = []
        var start: Date?
        var prev: Date?
        for p in points {
            if p.onAC {
                if start == nil { start = p.t }
                prev = p.t
            } else if let s = start, let e = prev {
                runs.append((s, e.addingTimeInterval(900))); start = nil; prev = nil
            }
        }
        if let s = start, let e = prev { runs.append((s, e.addingTimeInterval(900))) }
        return runs
    }
}
