import SwiftUI

struct PopoverView: View {
    @ObservedObject var store = HistoryStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showCalendar: Bool
    /// Which hours are folded open. Hour-of-day, so it survives a redraw but
    /// not a day change -- see the reset in `table`. Session state only:
    /// nothing about which rows were open is worth writing to disk.
    @State private var expanded: Set<Int> = []
    /// Render-only: `--render ... expand` opens every hour, so a capture can
    /// show the folded-open state. Set in the argument domain and never written
    /// by the UI -- see `TabPreference.forceForThisProcess`.
    static let expandAllKey = "BatteryExpandAll"
    private let expandAll = UserDefaults.standard.bool(forKey: PopoverView.expandAllKey)
    var onQuit: () -> Void

    init(openCalendar: Bool = false, onQuit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        _showCalendar = State(initialValue: openCalendar)
        self.onQuit = onQuit
    }

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(store.day)
            ? "'Today' · EEE d MMM" : "EEE d MMM yyyy"
        return f.string(from: store.day)
    }

    var body: some View {
        // The calendar floats OVER the table rather than pushing it down: an
        // NSPopover does not reliably resize to a changing SwiftUI frame, and a
        // popover that clips its own date picker is worse than one that overlaps.
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                if !store.chart.isEmpty {
                    BatteryChartView(day: store.day, points: store.chart, scheme: scheme)
                }
                hairline
                columnHeader
                table
                hairline
                footer
            }
            if showCalendar {
                Color.black.opacity(0.10)
                    .onTapGesture { showCalendar = false }
                calendar
                    .padding(.leading, 62).padding(.top, 42)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", enabled: true) { store.step(-1) }
            navButton("chevron.right", enabled: store.canGoForward) { store.step(1) }

            Button {
                showCalendar.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                    Text(dayLabel).fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(showCalendar ? 0.12 : 0.06)))

            Spacer(minLength: 4)

            if !Calendar.current.isDateInToday(store.day) {
                Button("Today") { store.day = Calendar.current.startOfDay(for: Date()) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.system(size: 11))
            }

            batteryStatus
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var calendar: some View {
        DatePicker("", selection: $store.day,
                   in: store.earliestDay...Date(),
                   displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            .fixedSize()
            .onChange(of: store.day) { _, _ in showCalendar = false }
    }

    /// Right of the header: what the battery is doing now, and what it is still
    /// worth. Maximum Capacity is the same figure System Settings shows.
    private var batteryStatus: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 4) {
                if let b = store.live {
                    if b.isCharging {
                        Image(systemName: "bolt.fill").font(.system(size: 8))
                            .foregroundStyle(.green)
                    }
                    Text("\(b.percent)%").font(.system(size: 12, weight: .semibold))
                    Text(b.isCharging ? "charging" : (b.onAC ? "on power" : "on battery"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let h = store.health {
                Text("health \(h.maximumCapacity) · \(h.cycleCount) cycles")
                    .font(.system(size: 9))
                    .foregroundStyle(h.condition == "Good" || h.condition == "Normal"
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .help("Condition: \(h.condition)")
            }
        }
    }

    private func navButton(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: table

    /// One faint rule instead of full-strength dividers: four hard lines chopped the
    /// panel into boxes and made a quiet table look busier than the data in it.
    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }

    /// Two stacked labels for the last column, because each row is two stacked
    /// lines there. Naming the second line in the header is what keeps it out
    /// of the rows -- a "CPU" tag repeated 24 times is exactly the noise the
    /// PWR chip was removed for.
    ///
    /// It says CPU. It does not say energy, power or battery use, and that is
    /// not a wording preference: nothing on this machine attributes watts to a
    /// process, the daemon deliberately records cycles instead, and a column
    /// headed "energy" would quietly undo that.
    /// Just the clock time, for the coverage note in the column header.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var columnHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: HourCols.disclosure, height: 1)
            Text("HOUR").frame(width: HourCols.hour, alignment: .leading)
            Text("LEVEL").frame(width: HourCols.level, alignment: .trailing)
            Text("Δ").frame(width: HourCols.delta, alignment: .trailing)
            Text("").frame(width: HourCols.bolt)
            VStack(alignment: .leading, spacing: 2) {
                if store.cpuRecorded {
                    // A day the stream joined part way through says so ONCE,
                    // here. The alternative -- a "not recorded" line on each of
                    // the hours above it -- was tried and was worse: on the day
                    // recording began it filled the pane with a sentence about
                    // absent data and pushed four rows of present data off the
                    // bottom. Same reasoning as the whole-day case below.
                    Text({
                        let head = store.powerRecorded ? "WHERE IT WENT" : "TOP CPU"
                        return store.cpuCoverFrom.map { "\(head) \u{00b7} FROM \(Self.clock.string(from: $0))" } ?? head
                    }())
                        .foregroundStyle(.tertiary)
                        .help(store.powerRecorded
                              ? "Each app's share of the battery for that hour, in percentage points — the same unit as the Δ column. The chip's power is measured; the split between apps is attributed from their share of the work. Below the apps, the hardware that was awake: on-time only, because nothing on this Mac measures what a camera or a speaker costs."
                              : "The three processes that burned the most CPU cycles in the hour. CPU work, not energy: nothing was measuring power on this day.")
                } else {
                    Text("WHAT WAS IN FRONT")
                        .help("Nothing was recording which processes were busy on this day. The CPU stream keeps 14 days and began only recently; battery history is kept forever, so an older day has a charge curve and no CPU.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The two figures that used to be punctuation inside the app line.
            // Both are per-app, and a column is the only shape in which a
            // reader can compare one app with the app directly under it.
            if store.cpuRecorded {
                Text(store.powerRecorded ? "SHARE" : "")
                    .frame(width: HourCols.share, alignment: .trailing)
                    .help("This app\u{2019}s share of the battery for the hour, in percentage points \u{2014} the same unit as the \u{0394} column. The apps do not add up to \u{0394}, and are not meant to: most of the drain is the display, the radios and idle silicon, which is the \u{2018}rest\u{2019} row inside the hour.")
                Text("TIME")
                    .frame(width: HourCols.cpu, alignment: .trailing)
                    .help("How long the thing on the left was working.\n\nFor an app it is PROCESSOR time \u{2014} an app that kept four cores busy for one minute reads 4.0m, so a figure here can exceed the hour it sits in.\n\nFor a piece of hardware it is wall clock, the part of the hour it was switched on, and it says 'on' to mark the difference. The two are not comparable and the word is there so they are not compared.")
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
    }

    private var table: some View {
        Group {
            if store.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bolt.slash").font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("No charge samples for this day")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("The Mac was off, or this day is older than anything recorded.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Eager, not lazy. The table is bounded -- 24 hours of at
                    // most eight apps and a remainder -- so there is nothing to
                    // win by deferring rows, and a LazyVStack left the folded
                    // open hours blank in the offscreen `--render` capture,
                    // which is the only way this layout gets checked.
                    VStack(spacing: 0) {
                        ForEach(store.rows) { row in
                            let lines = AppLine.lines(for: row)
                            let open = expanded.contains(row.hour) || expandAll
                            HourRowView(row: row,
                                        showCPU: store.cpuRecorded,
                                        first: lines.first,
                                        hidden: max(lines.count - 1, 0),
                                        expanded: open,
                                        onToggle: { toggle(row.hour) })
                            if open {
                                ForEach(lines.dropFirst()) { line in
                                    AppChildRow(line: line)
                                }
                            }
                        }
                    }
                }
                // An open hour on Tuesday is not the same hour on Wednesday --
                // the apps behind it are different -- so the folds shut when
                // the day moves rather than reopening on unrelated rows.
                .onChange(of: store.day) { _, _ in expanded.removeAll() }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func toggle(_ hour: Int) {
        if expanded.contains(hour) { expanded.remove(hour) } else { expanded.insert(hour) }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            if store.rows.isEmpty {
                Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Label("\(store.summary.drained)% used", systemImage: "arrow.down")
                    .foregroundStyle(.red)
                Label("\(store.summary.charged)% gained", systemImage: "arrow.up")
                    .foregroundStyle(.green)
                if let w = store.summary.worstHour, w.delta < 0 {
                    Text("worst \(w.label) (\(w.delta)%)").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { HistoryStore.shared.backfill(force: true) } label: {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.plain).help("Re-read the system power log")
            Menu {
                Button("Open Battery Settings…") { PopoverView.openBatterySettings() }
                Divider()
                Button("Quit System Monitor") { onQuit() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
            .help("Battery settings")
        }
        .font(.system(size: 11))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

extension PopoverView {
    static func openBatterySettings() {
        // macOS 13+ pane id; the old preference-pane id still resolves as a fallback.
        for id in ["x-apple.systempreferences:com.apple.Battery-Settings.extension",
                   "x-apple.systempreferences:com.apple.preference.battery"] {
            if let u = URL(string: id), NSWorkspace.shared.open(u) { return }
        }
    }
}


// =====================================================================
// MARK: - Column geometry
// =====================================================================

/// One place for the table's column widths. The header, the hour rows and the
/// app rows underneath them all read from here, because a tree whose child
/// indent is a separate literal from its parent's columns drifts the first
/// time a column is resized -- which is exactly how the app column and its
/// header last parted company.
private enum HourCols {
    static let disclosure: CGFloat = 15
    static let hour: CGFloat = 84
    static let level: CGFloat = 44
    static let delta: CGFloat = 52
    static let bolt: CGFloat = 22
    static let share: CGFloat = 58
    /// Wide enough for "60m on" -- the hardware rows carry that word in the
    /// cell, because it is the only thing separating wall clock from an app's
    /// processor time one row above it.
    static let cpu: CGFloat = 64
    /// The slot "on" hangs in, to the right of the digits. Splitting it out is
    /// what keeps every figure in the column aligned on the same right edge.
    static let timeNote: CGFloat = 16
    /// Everything to the left of the app name. A child row indents by exactly
    /// this, so an app under an hour starts where the hour's own first app
    /// starts rather than at some hand-tuned offset near it.
    static var appLead: CGFloat { disclosure + hour + level + delta + bolt }
}

// =====================================================================
// MARK: - One app's line in an hour
// =====================================================================

/// One app inside one hour, already formatted: the name, its share of the
/// battery and the CPU time behind it.
///
/// Built once per hour and handed to both row views, so the collapsed row and
/// the rows it folds open cannot disagree about which app came first or what
/// its numbers were. The old single-line renderer built the string and the
/// tooltip separately and they had already drifted.
private struct AppLine: Identifiable {
    let id: String
    let name: String
    /// Battery percentage points, or nil when nothing measured power that hour.
    let share: String?
    /// CPU time for an app, wall-clock on-time for a device, nil on the
    /// remainder row -- no process to time.
    let cpu: String?
    /// A word after the figure, hung outside the numeric column so the digits
    /// still line up: "on", on the rows whose time is wall clock rather than
    /// processor time. The unit column of this table is zero-padded and
    /// monospaced on purpose, and a suffix inside it would rag every number in
    /// the fold to the left of it.
    let timeNote: String?
    /// Drawing done by WindowServer is folded in: a correlation, marked.
    let drawing: Bool
    /// The remainder row. Styled apart because it is not an app.
    let isRest: Bool
    /// A piece of hardware rather than a program.
    let isHardware: Bool
    /// The share is FITTED rather than measured -- brightness was read, the
    /// watts behind it were not. Marked in the row, because a number that means
    /// something different must not look identical to the ones around it. Same
    /// reasoning as the `\u{2731}` on an app whose figure folds in WindowServer.
    let fitted: Bool
    /// What the row sorts on. Rows with no share at all sort below every row
    /// that has one, whatever their on-time -- an unpriced hour of camera is
    /// not evidence that it beat a priced app.
    let sortKey: Double
    let help: String

    /// Every app row for an hour, busiest first, with the remainder last.
    ///
    /// The apps under a hundredth of a point stay: they were dropped when all
    /// of this had to fit on one line, and a folded-open row has the height to
    /// be honest about a long tail instead of implying there is not one.
    static func lines(for row: HourRow) -> [AppLine] {
        // An hour with nothing busy can still have had the screen on for all
        // sixty minutes, and that is worth a row -- so only a genuinely
        // unrecorded hour returns nothing. `.idle` falls through with no apps
        // and whatever hardware was awake.
        if case .notRecorded = row.cpu { return [] }
        let shares: [CPUShare] = { if case .busy(let s) = row.cpu { return s }; return [] }()
        var out = shares.map { s in
            AppLine(id: s.name,
                    name: s.name,
                    share: s.pointsLabel,
                    cpu: s.duration,
                    timeNote: nil,
                    drawing: s.includesDrawing,
                    isRest: false,
                    isHardware: false,
                    fitted: false,
                    sortKey: s.points ?? -1,
                    help: helpText(s, row: row))
        }

        // The hardware, between the apps and the remainder, because that is
        // what it itemises: the apps above it have measured shares, the rows
        // below say 13.8% went somewhere, and these name the things that were
        // awake to take it. They carry no share on purpose -- nothing on this
        // machine measures what a camera or a speaker costs, and the
        // coefficient that would price the screen is not fitted yet. Putting a
        // plausible number here would be the one thing this tab refuses to do.
        for d in row.devices where d.seconds > 0 {
            out.append(AppLine(id: "\u{2022}" + d.id,
                               name: d.label,
                               share: d.points.map(Self.pointsLabel),
                               cpu: d.minutesOnly,
                               timeNote: "on",
                               drawing: false,
                               isRest: false,
                               isHardware: true,
                               fitted: d.points != nil,
                               sortKey: d.points ?? -1,
                               help: hardwareHelp(d, row: row)))
        }

        // One ranked list, because the fold's question is "where did it go" and
        // on most hours the answer is the screen rather than any app. Rows that
        // carry no share at all fall to the bottom of it: a camera nobody has
        // priced is not evidence that it beat an app, and sorting it by
        // on-time against a percentage would say exactly that.
        out.sort { $0.sortKey > $1.sortKey }

        // Last, and never first: it is usually the largest figure in the hour,
        // and a reader who meets it at the top of the fold reads it as an app.
        // What is left after the apps AND the hardware that now has a price. It
        // has to shrink by exactly what the screen row shows, or the two rows
        // charge the hour twice for the same watts.
        if let raw = row.systemPoints {
            let priced = row.devices.compactMap(\.points).reduce(0, +)
            let rest = max(0, raw - priced)
            guard rest >= 0.05 else { return out }
            out.append(AppLine(id: "\u{2022}rest",
                               name: "rest",
                               share: Self.pointsLabel(rest),
                               cpu: nil,
                               timeNote: nil,
                               drawing: false,
                               isRest: true,
                               isHardware: false,
                               fitted: false,
                               sortKey: -2,
                               help: restHelp(row)))
        }
        return out
    }

    /// What a hardware row can and cannot say. The second half is the point:
    /// a reader who sees "57m on" next to an empty share will otherwise assume
    /// the app forgot to fill it in.
    /// The remainder, and what is now known about it. Where `draw` covered the
    /// hour the machine's total is a reading, so the sentence can say how much
    /// of it the chip was -- which is the fact that makes the size of this row
    /// stop looking like a bug.
    private static func restHelp(_ row: HourRow) -> String {
        var out = "Everything no app can be held to: the display, the radios, "
        out += "idle silicon and every root-owned service. On this machine that "
        out += "is usually most of the hour's drain."
        if let mw = row.machineMw {
            out += "\n\nMeasured: the whole machine drew " + watts(mw) + " this hour. "
            out += "The chip is a small minority of that, and the hardware rows "
            out += "above name what was awake to take the difference \u{2014} "
            out += "none of it is priced yet."
        }
        return out
    }

    private static func hardwareHelp(_ d: DeviceUse, row: HourRow) -> String {
        var out = d.label
        if d.name != d.kind, !d.name.isEmpty, d.name != "screen" { out += " \u{2014} " + d.name }
        out += "\nOn for " + d.onLabel.replacingOccurrences(of: " on", with: "")
             + " of the hour's 60 minutes.\n\n"
        if let p = d.points {
            out += "About " + Self.pointsLabel(p) + " of the battery \u{2014} a FITTED "
            out += "figure, marked ~. The panel's brightness was read every minute; "
            out += "the watts behind it come from one coefficient measured on this "
            out += "machine (9.05 W at full brightness, fitted over six levels with "
            out += "the rest of the Mac idle). It is a good deal firmer than a guess "
            out += "and it is not a measurement."
        } else {
            out += "No share of the battery, because none was measured. This Mac "
            out += "publishes a power figure for the chip and a brightness for the "
            out += "screen, and nothing at all for a camera, a radio or a speaker "
            out += "\u{2014} so what these cost stays inside 'rest'."
        }
        if let mw = row.machineMw {
            out += "\n\nThe whole machine drew " + Self.watts(mw) + " this hour, measured."
        }
        return out
    }

    /// Milliwatts as watts, one decimal. The figure carries the pack voltage's
    /// own swing, so a second decimal would be inventing precision.
    static func watts(_ mw: Int) -> String {
        String(format: "%.1f W", Double(mw) / 1000)
    }

    /// Percentage points, at the precision the figure deserves. Same thresholds
    /// as `CPUShare.pointsLabel`, because two rows in one column showing the
    /// same magnitude to different precision reads as a bug.
    static func pointsLabel(_ p: Double) -> String {
        if p >= 10 { return String(format: "%.0f%%", p) }
        if p >= 1 { return String(format: "%.1f%%", p) }
        if p >= 0.01 { return String(format: "%.2f%%", p) }
        return "<0.01%"
    }

    private static func helpText(_ s: CPUShare, row: HourRow) -> String {
        var out = s.name + "\n"
        if let label = s.pointsLabel {
            out += label + " of the battery this hour, from " + s.duration
                 + " of CPU at " + s.averageClock + " average.\n"
        } else {
            out += s.duration + " of CPU at " + s.averageClock + " average.\n"
            out += "CPU work, not energy: nothing measured power this hour.\n"
        }
        if s.includesDrawing {
            out += "\nIncludes drawing done for it by WindowServer \u{2014} a correlation, not a measurement.\n"
        }
        if !row.who.isEmpty { out += "\nIn front this hour: " + row.who }
        return out
    }
}

// =====================================================================
// MARK: - One hour
// =====================================================================

/// The hour, and the app that used most of it. The rest of its apps are rows
/// of their own underneath, drawn only while the hour is folded open.
///
/// Folded shut by default, and the fold is the point: an hour is worth one
/// line of the pane until someone asks it a question, and twenty-four hours of
/// eight apps each is not a table anyone reads.
private struct HourRowView: View {
    let row: HourRow
    /// The day has cpu data somewhere. When it has none the app column falls
    /// back to what was in front and the column header says so once -- 24 rows
    /// of "not recorded" would drown the column that does work.
    let showCPU: Bool
    /// The busiest app of the hour, shown on the collapsed row.
    let first: AppLine?
    /// How many app rows are behind the fold.
    let hidden: Int
    let expanded: Bool
    let onToggle: () -> Void

    private var deltaColor: Color {
        row.delta < 0 ? .red : (row.delta > 0 ? .green : .secondary)
    }

    /// An hour with nothing behind the first app does not pretend to open.
    private var foldable: Bool { showCPU && hidden > 0 }

    /// What the hour cost, in watts, where that was measured rather than worked
    /// out backwards from the charge curve.
    ///
    /// It lives on the hour's own label because it is a fact about the hour and
    /// not about any row inside it -- and because it is the number that makes
    /// the rest of the fold legible: twelve watts against a chip drawing one is
    /// the whole reason the remainder is the size it is.
    private var hourHelp: String {
        var out = row.label + "\n" + (row.delta == 0 ? "level" :
            (row.delta < 0 ? "\(-row.delta) points lost" : "\(row.delta) points gained"))
        if let mw = row.machineMw {
            out += "\n\nThe machine drew " + AppLine.watts(mw) + " this hour, measured."
        }
        if !row.measured {
            out += "\n\nBoth ends of this hour were interpolated across a gap in the "
            out += "charge log \u{2014} nothing sampled inside it."
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // A plus/minus box rather than a chevron, matching the Net tab: the
            // chevron here would rhyme with the one in the day picker above,
            // which points at a menu and not at a subtree.
            Image(systemName: expanded ? "minus.square" : "plus.square")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: HourCols.disclosure, alignment: .leading)
                .opacity(foldable ? 1 : 0)

            Text(row.label)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: HourCols.hour, alignment: .leading)
                .foregroundStyle(row.measured ? .primary : .secondary)
                .help(hourHelp)

            // START is gone: it is always the previous row's LEVEL. The charge
            // itself stays -- an hour table with only deltas cannot answer "what
            // was I at", which is the question this whole thing exists for.
            Text("\(row.endPct)%")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: HourCols.level, alignment: .trailing)

            // no delta bar: the chart above already carries magnitude, and repeating
            // it 24 times in a cruder form was most of the noise in this table
            Text(row.delta == 0 ? "0%" : String(format: "%+d%%", row.delta))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(deltaColor)
                .frame(width: HourCols.delta, alignment: .trailing)

            // PWR was a filled chip on all 24 rows for a value that barely changes.
            // A bolt when it was on power, nothing when it was not.
            Group {
                if row.source.contains("AC") {
                    Image(systemName: "bolt.fill").font(.system(size: 8))
                        .foregroundStyle(.green)
                } else {
                    Color.clear
                }
            }
            .frame(width: HourCols.bolt)

            appColumn
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { if foldable { onToggle() } }
    }

    /// The last three columns: which app, its share, its CPU time. On a day
    /// with no cpu stream it collapses back to what was in front, which is the
    /// only thing that day knows.
    @ViewBuilder private var appColumn: some View {
        if !showCPU {
            Text(row.who.isEmpty ? "\u{2014}" : row.who)
                .font(.system(size: 11))
                .foregroundStyle(row.who.isEmpty ? .tertiary : .secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(row.who)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let first {
            appCells(first, child: false, moreHidden: expanded ? 0 : hidden)
        } else {
            emptyHour
        }
    }

    /// The hour had no app rows, and which of the two reasons it was matters --
    /// see `HourCPU`. Both keep the two numeric columns empty rather than
    /// filling them with dashes: there is no figure, and a dash column reads as
    /// a measured zero.
    @ViewBuilder private var emptyHour: some View {
        Group {
            switch row.cpu {
            case .busy:
                // Power WAS measured and no app reached a hundredth of a point
                // -- the overnight case. Dropping back to CPU time here would
                // quietly change the column's unit mid-table.
                Text("\u{2014}")
                    .foregroundStyle(.tertiary)
                    .help("Power was measured this hour and no app reached 0.01% of the battery. "
                          + "The machine was asleep or idle; the charge that moved went to the "
                          + "display, the radios and idle silicon.")
            case .idle:
                // Words, not a dash: a dash here would read the same as the
                // line below it, which means the opposite thing.
                Text("nothing busy")
                    .foregroundStyle(.tertiary)
                    .help("Recorded, and no process of yours crossed the floor the daemon records above (~50M cycles a minute). The Mac may also have been asleep.")
            case .notRecorded:
                // Nothing at all. The header states the stream's boundary once
                // for the whole day; repeating "not recorded" down the column
                // spends rows on the absence of data and reads as a fault.
                Text("")
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// =====================================================================
// MARK: - One app under an hour
// =====================================================================

/// An app that is not the busiest of its hour, or the remainder. Indented to
/// the app column and otherwise identical to the line on the hour row above
/// it, so the fold adds rows and never a second way of reading them.
private struct AppChildRow: View {
    let line: AppLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: HourCols.appLead, height: 1)
            appCells(line, child: true, moreHidden: 0)
        }
        .padding(.horizontal, 12).padding(.bottom, 5)
    }
}

/// Name, share, CPU time -- the three cells an app occupies, on the hour row
/// and on a child row alike.
///
/// A builder function rather than a `View`, deliberately: these are three
/// siblings in the caller's own HStack, and wrapping them in a view would nest
/// a second layout inside the row and let the child's columns drift out of
/// line with the hour's.
///
/// `moreHidden` is the count still behind the fold, shown after the name. Zero
/// on an open hour and on every child row.
@ViewBuilder private func appCells(_ line: AppLine, child: Bool, moreHidden: Int) -> some View {
    Group {
        HStack(spacing: 4) {
            Text(line.name + (line.drawing ? "\u{2731}" : "") + (line.fitted ? "\u{00a0}~" : ""))
                .font(.system(size: 11, weight: child ? .regular : .medium))
                .foregroundStyle(line.isRest ? AnyShapeStyle(.tertiary)
                                 : line.isHardware ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(child ? .secondary : .primary))
                .lineLimit(1).truncationMode(.tail)
            // What the fold is hiding, as a number rather than as a promise.
            // Without it a collapsed hour claims one app used it.
            if moreHidden > 0 {
                Text("+\(moreHidden)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(line.help)

        Text(line.share ?? "\u{2014}")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(line.share == nil ? AnyShapeStyle(.tertiary)
                                               : AnyShapeStyle(line.isRest ? .tertiary : .secondary))
            .frame(width: HourCols.share, alignment: .trailing)

        HStack(spacing: 3) {
            Text(line.cpu ?? "")
                .frame(width: HourCols.cpu - HourCols.timeNote - 3, alignment: .trailing)
            Text(line.timeNote ?? "")
                .frame(width: HourCols.timeNote, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: HourCols.cpu, alignment: .trailing)
    }
}
