import SwiftUI

/// Traffic across one day: down BELOW the centre line, up above it.
///
/// Which way round is not arbitrary. Bytes arriving are described everywhere
/// else as coming "down", so a download that grows upwards reads against its
/// own name; the mirror is only worth having if each half points the way its
/// label already says.
///
/// Deliberately built to the Battery chart's geometry -- same gutters, same
/// plot height, same 3-hourly labels on a fixed midnight-to-midnight axis --
/// so switching tabs does not move the furniture and a spike here can be lined
/// up by eye against the charge curve there.
///
/// The axis is the WHOLE day even when only part of it has happened, for the
/// same reason the Battery chart pins its own: scaling to whatever has been
/// recorded makes every day a different shape and destroys the one thing a
/// daily chart is for, which is comparing one day with another. This replaced
/// a rolling sparkline whose window grew with the session -- the right choice
/// when the pane could only ever show "since you opened this", and the wrong
/// one now that it shows a named day.
struct NetDayChartView: View {
    let day: Date
    /// 96 buckets of 15 minutes, midnight first. Empty while nothing is known.
    let ticks: [NetTick]
    let scheme: ColorScheme

    private let rightGutter: CGFloat = 36
    private let bottomGutter: CGFloat = 20
    private let plotHeight: CGFloat = 62
    private let topPad: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in draw(ctx, size) }
            .frame(height: plotHeight + bottomGutter + topPad)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 14)
    }

    /// Biggest single bucket in either direction. One scale for both halves, so
    /// the mirror is honest: a tall spike below the line really did move more
    /// than a short one above it.
    private var peak: Int64 {
        max(ticks.map { max($0.down, $0.up) }.max() ?? 0, 1)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let midnight = Calendar.current.startOfDay(for: day)
        let plot = CGRect(x: 0, y: topPad, width: size.width - rightGutter, height: plotHeight)
        let zero = plot.midY
        let half = plot.height / 2

        func x(_ t: TimeInterval) -> CGFloat {
            plot.minX + CGFloat(t / 86_400) * plot.width
        }

        // Zero rule, then a faint bound at each extreme. Three lines, matching
        // the Battery chart's 0/50/100 -- any more and the grid competes with
        // the data, which in a quiet day is a handful of thin bars.
        for (y, weight) in [(zero, 0.16), (plot.minY, 0.07), (plot.maxY, 0.07)] {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(line, with: .color(.primary.opacity(weight)), lineWidth: 0.5)
        }
        // The scale is shared, so the peak is labelled on the half it belongs
        // to and the other end only needs the zero. Labelling both extremes
        // with the same number would imply two scales.
        ctx.draw(Text(NetFormat.bytes(peak)).font(.system(size: 9)).foregroundStyle(.secondary),
                 at: CGPoint(x: plot.maxX + 6, y: plot.minY), anchor: .leading)
        ctx.draw(Text("0").font(.system(size: 9)).foregroundStyle(.secondary),
                 at: CGPoint(x: plot.maxX + 6, y: zero), anchor: .leading)

        for h in stride(from: 0, to: 24, by: 3) {
            let label = h == 0 ? "12A" : (h == 12 ? "12P" : "\(h % 12)")
            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: x(Double(h) * 3600) + 1, y: plot.maxY + 13), anchor: .leading)
        }

        guard !ticks.isEmpty else { return }

        // One bar per bucket, drawn as a rectangle rather than a line: at 96
        // slots across ~480pt a bucket is 5pt wide, and a stroked path that
        // narrow renders as a comb of gaps at some scale factors.
        let slot = plot.width / CGFloat(ticks.count)
        let w = max(slot - 0.8, 1)
        let scale = CGFloat(peak)

        for (i, t) in ticks.enumerated() {
            let left = plot.minX + CGFloat(i) * slot
            if t.up > 0 {
                let h = max(half * CGFloat(t.up) / scale, 1)
                ctx.fill(Path(CGRect(x: left, y: zero - h, width: w, height: h)),
                         with: .color(NetPalette.up(scheme)))
            }
            if t.down > 0 {
                let h = max(half * CGFloat(t.down) / scale, 1)
                ctx.fill(Path(CGRect(x: left, y: zero, width: w, height: h)),
                         with: .color(NetPalette.down(scheme)))
            }
        }

        // Where the day stopped. Only on today, and only as a hairline: without
        // it an empty afternoon and an afternoon that has not happened yet draw
        // exactly the same, which is the one lie a fixed axis can tell.
        if Calendar.current.isDateInToday(day) {
            let nowX = x(Date().timeIntervalSince(midnight))
            var line = Path()
            line.move(to: CGPoint(x: nowX, y: plot.minY))
            line.addLine(to: CGPoint(x: nowX, y: plot.maxY))
            ctx.stroke(line, with: .color(.primary.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            ctx.fill(Path(CGRect(x: nowX, y: plot.minY,
                                 width: max(plot.maxX - nowX, 0), height: plot.height)),
                     with: .color(.primary.opacity(0.035)))
        }
    }
}
