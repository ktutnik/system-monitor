import Foundation
import Combine

struct Sample {
    var time: Date
    var onAC: Bool
    var percent: Int
}

struct ChartPoint: Identifiable {
    var id: Date { t }
    var t: Date
    var pct: Int
    var onAC: Bool
}

/// One process's share of an hour's CPU work. Ranked on `cycles`, shown as
/// `cpuMs` -- see `HourCPU`.
struct CPUShare {
    var name: String
    var cycles: Int64
    var cpuMs: Int

    /// PERCENTAGE POINTS OF BATTERY attributed to this app for the hour, or nil
    /// when nothing was measuring power (the `power` stream needs the root
    /// helper, and the helper is opt-in).
    ///
    /// Derived, and every step is worth knowing before anyone quotes it:
    /// the chip's MEASURED average power over the hour, times this app's share
    /// of the work, divided by the watt-hours in one point of THIS battery. The
    /// measurement is real; the split is an attribution.
    var points: Double?

    /// True when this app's figure includes WindowServer time folded in from
    /// the hours it held the screen. Marked in the UI, because that part is a
    /// correlation rather than a measurement -- an app animating behind a static
    /// front window would be misattributed.
    var includesDrawing: Bool = false

    /// One decimal below ten points, two below one: the numbers are small by
    /// nature -- the chip is a minority of this machine's draw -- and rounding
    /// them to whole points would render every app as 0%.
    var pointsLabel: String? {
        guard let p = points else { return nil }
        if p >= 10 { return String(format: "%.0f%%", p) }
        if p >= 1 { return String(format: "%.1f%%", p) }
        if p >= 0.01 { return String(format: "%.2f%%", p) }
        return "<0.01%"
    }

    /// CPU TIME, not energy and not a percentage. Milliseconds below a second,
    /// then seconds, then minutes -- an hour's sum for a busy app lands in
    /// minutes and a multi-core one can exceed sixty of them, which is correct.
    var duration: String {
        if cpuMs < 1000 { return "\(cpuMs)ms" }
        let s = Double(cpuMs) / 1000
        return s < 60 ? String(format: "%.0fs", s) : String(format: "%.1fm", s / 60)
    }

    /// cycles / cpu time recovers the clock the work actually ran at, which is
    /// how you tell afterwards whether it landed on a performance core or an
    /// efficiency one. Neither column carries that alone.
    var averageClock: String {
        guard cpuMs > 0 else { return "—" }
        return String(format: "%.1f GHz", Double(cycles) / Double(cpuMs) / 1_000_000)
    }
}

/// What the cpu stream can say about one hour. Three cases, and the whole point
/// of the type is that the UI must not render them the same way.
///
/// `.idle` and `.notRecorded` are the pair that matters. The daemon only writes
/// a process that burned more than ~50M cycles in a minute, so a quiet hour
/// genuinely produces no rows and "nothing was busy" is the truth. An hour
/// outside the stream's coverage produces no rows either, and there the truth
/// is "nobody was looking". Collapsing them into one blank cell is exactly the
/// silent failure this app's design rules forbid -- and it is the COMMON case,
/// not an edge one: the stream began part-way through a day, and it is pruned
/// after 14 days while the battery history beside it is kept forever.
enum HourCPU {
    /// The stream was not recording this hour. Says nothing about CPU use.
    case notRecorded
    /// Recorded, and nothing crossed the daemon's floor -- or the machine slept.
    case idle
    /// Top processes by summed cycles over the hour, busiest first.
    case busy([CPUShare])
}

/// One piece of hardware that was on during an hour, and for how long.
///
/// No share of the battery, and the missing field is the honest part: nothing on
/// this machine measures what a camera or a speaker costs, and the coefficient
/// that would price the screen has not been fitted yet. On-time is what was
/// recorded, so on-time is what this carries.
struct DeviceUse: Identifiable {
    var id: String { kind + "\u{0000}" + name }
    var kind: String          // camera | audio_in | audio_out | screen
    var name: String
    var seconds: Int

    /// Percentage points of battery, FITTED -- the same unit as an app's share
    /// and not the same kind of number. nil for everything but the screen,
    /// because the screen is the only piece of hardware on this Mac whose
    /// output can be read at all; see `ScreenCalibration`.
    var points: Double?

    /// Minutes, to the nearest one. The row is about which part of the hour a
    /// thing was awake for, and a second either way does not change that.
    var minutes: Int { Int((Double(seconds) / 60).rounded()) }

    /// How long it was on, in the unit the figure actually lands in.
    ///
    /// Seconds below a minute rather than a rounded-down "0m", because a camera
    /// that ran for twenty seconds IS the answer to why the green light came on,
    /// and rounding it out of existence would hide a real event behind a unit
    /// choice. Same reasoning as `CPUShare.duration` one screen up.
    var onLabel: String { minutesOnly + " on" }

    /// The figure alone, for the column that hangs the "on" beside it.
    var minutesOnly: String {
        seconds < 60 ? "\(seconds)s" : "\(minutes)m"
    }

    /// What the row calls itself. `screen` is a device like the others here even
    /// though it comes from `activity` rather than `device`: it is the largest
    /// consumer in most hours and leaving it out because it arrives by a
    /// different road would be the wrong kind of tidiness.
    var label: String {
        switch kind {
        case "screen":    return "screen"
        case "camera":    return "camera"
        case "audio_out": return "audio out"
        case "audio_in":  return "audio in"
        default:          return kind
        }
    }
}

/// Watts per unit of screen brightness, fitted once and kept on disk.
///
/// The consumer's model, deliberately NOT in `~/Vitals`: the store holds what
/// was read, and this is what was inferred from it. Absent file means no
/// coefficient, which means the screen row shows on-time and no share -- the
/// state this app shipped in before the sweep was run.
///
/// Fitted 2026-09-22 from six brightness levels held three minutes each, out of
/// order, on an idle machine: 9.05 mW per per-mille, R2 0.984 over 22 samples.
/// That puts the panel at 9.05 W wide open and 2.5 W at the middle of the
/// slider, against a 4.4 W baseline for everything that is not the screen.
struct ScreenCalibration {
    let mwPerPerMille: Double

    /// nil when the file is missing or unreadable, or when the coefficient is
    /// outside 2-15 W at full brightness. That bound is not decoration: a fit
    /// on too little data, or on hours where something else moved with the
    /// brightness, lands far outside it, and a wrong number here would be
    /// spread across every hour in the table wearing the same clothes as a
    /// measurement.
    static func load() -> ScreenCalibration? {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SysMonitor/screen-calibration.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let k = obj["mwPerPerMille"] as? Double,
              k * 1000 >= 2000, k * 1000 <= 15000 else { return nil }
        return ScreenCalibration(mwPerPerMille: k)
    }
}

struct HourRow: Identifiable {
    var id: Int { hour }
    var hour: Int
    var label: String          // "09:00-10:00"
    var startPct: Int
    var endPct: Int
    var delta: Int { endPct - startPct }
    var source: String         // "Batt", "AC", "Batt->AC"
    var measured: Bool         // false = both ends interpolated across a gap
    var who: String
    var cpu: HourCPU = .notRecorded

    /// Points the hour lost that no app can be held to: screen, radios, idle
    /// silicon, and every root-owned service. nil when the hour was charging or
    /// nothing measured power.
    ///
    /// It is shown rather than hidden because without it the column reads as
    /// broken arithmetic -- on this machine the chip is a small minority of the
    /// draw, so three apps at a fraction of a point each sit beside a Δ of
    /// twelve. The remainder IS the answer to "where did it actually go".
    var systemPoints: Double?

    /// What the WHOLE MACHINE drew this hour, averaged from the `draw` stream.
    /// nil for every hour the stream does not cover, which is every hour before
    /// it existed -- and the tab must keep saying what it used to for those
    /// rather than showing a blank where a number would be.
    ///
    /// Where it is present it replaces an inference. `systemPoints` above is
    /// arithmetic on the battery percentage; this is a reading.
    var machineMw: Int?

    /// Hardware that was awake during the hour, busiest first. Screen, then
    /// whatever `device` recorded.
    var devices: [DeviceUse] = []
}

struct DaySummary {
    var drained: Int = 0       // total % lost
    var charged: Int = 0       // total % gained
    var worstHour: HourRow?
    var onBatteryHours: Double = 0
}

/// Charge history, kept by the app itself.
///
/// The system's own record of past charge reaches back about a week and is gone
/// after that, so it is used to BACKFILL a per-day store on disk -- and only for
/// the stretch that store does not already cover. Everything the UI reads comes
/// from that store, which stays instant and keeps growing past the point where
/// the system forgets.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var rows: [HourRow] = []
    @Published private(set) var chart: [ChartPoint] = []
    @Published private(set) var summary = DaySummary()
    @Published private(set) var availableDays: [String] = []
    /// Does the cpu stream hold anything at all for the day on screen? False
    /// for every day before it started recording and every day older than its
    /// 14-day window -- which is most of the battery history, since that is
    /// kept forever. The column header says so once rather than every row
    /// repeating it 24 times.
    @Published private(set) var cpuRecorded: Bool = false

    /// True when the `power` stream had rows for this day -- i.e. the root
    /// helper is installed. Without it the column falls back to CPU time, which
    /// is what it showed before any of this existed.
    @Published private(set) var powerRecorded: Bool = false

    /// True when the `draw` stream covered this day -- i.e. the machine's total
    /// draw was measured rather than inferred from the charge curve. False for
    /// every day before the stream was added, which is most of the history.
    @Published private(set) var drawRecorded: Bool = false

    /// True when the `device` stream covered this day. Note what it does NOT
    /// mean: the stream writes a row only for a device that was on, so an hour
    /// with no rows is an hour with nothing running. Without this flag that is
    /// indistinguishable from an hour nobody watched.
    @Published private(set) var deviceRecorded: Bool = false

    /// display name -> "is an application". Rebuilt on every reload, because
    /// the paths behind it come from that day's `proc` file.
    private var appNameCache: [String: Bool] = [:]
    /// When the stream's coverage of the shown day begins, if it begins part
    /// way through it. nil when the day is covered from midnight, or not at all.
    @Published private(set) var cpuCoverFrom: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var live: BatteryReading?
    @Published private(set) var health: BatteryHealth?
    @Published var day: Date = Calendar.current.startOfDay(for: Date()) {
        didSet { reload() }
    }

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "battery-history", qos: .utility)

    /// Where the day files are READ from: the vitalsd store.
    ///
    /// `vitals`' battery files are byte-identical to the ones this app used to
    /// write -- no header, `HH:MM:SS<TAB>source<TAB>percent` -- so the cutover is
    /// a path and nothing else. What changes is coverage: the daemon samples
    /// whether or not this panel is ever opened, so the week-long gaps that the
    /// open-only design accepted do not happen any more.
    ///
    /// Falls back to this app's own former directory when the daemon has never
    /// run, so an install without `vitals` still shows whatever was recorded
    /// before the cutover rather than an empty calendar.
    private lazy var dir: URL = {
        let vitals = VitalsStore.batteryDir
        if fm.fileExists(atPath: vitals.path) { return vitals }
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SysMonitor", isDirectory: true)
        try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        return legacy
    }()

    /// Where live samples this app takes itself are WRITTEN.
    ///
    /// Deliberately still the app's own directory, never the daemon's. Two
    /// writers appending to one file is a corruption waiting for a coincidence,
    /// and the rule from the vitals contract is that the daemon owns its store.
    /// These writes are a safety net for a machine with no daemon; where one is
    /// running they are redundant and harmless.
    private lazy var writeDir: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SysMonitor", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private lazy var dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private lazy var timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    /// `log show --start` wants local wall-clock time in this exact shape, and
    /// `--style compact` prints timestamps back in local time with no offset --
    /// so the same default time zone reads both ends.
    private lazy var logArgFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - writing

    private func file(_ dayString: String) -> URL {
        dir.appendingPathComponent("\(dayString).tsv")
    }

    /// The file this app appends to -- never the daemon's (see `writeDir`).
    private func writeFile(_ dayString: String) -> URL {
        writeDir.appendingPathComponent("\(dayString).tsv")
    }

    /// Append one live reading. Cheap enough to call every few minutes.
    /// Condition changes over months, not minutes -- read it at launch and leave it.
    func refreshHealth() {
        queue.async { [weak self] in
            let h = BatteryHealth.read()
            DispatchQueue.main.async { self?.health = h }
        }
    }

    func recordNow() {
        live = BatteryReading.current()
        guard let b = live else { return }
        let now = Date()
        write([Sample(time: now, onAC: b.onAC, percent: b.percent)],
              into: dayFmt.string(from: now))
        if Calendar.current.isDate(now, inSameDayAs: day) { reload() }
    }

    /// Merge samples into a day file, keeping one sample per second, sorted.
    ///
    /// Leaves the disk alone when the merge changes nothing. A backfill covering
    /// a stretch already held would otherwise rewrite every day file it touched
    /// -- nine atomic writes to land the same bytes that were there before.
    @discardableResult
    private func write(_ new: [Sample], into dayString: String) -> Bool {
        guard !new.isEmpty else { return false }
        var byTime: [String: String] = [:]
        // writeFile, not file: reads come from the daemon's store, writes never
        // go there. Two writers on one append-only file is a corruption waiting
        // for a coincidence.
        let url = writeFile(dayString)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if let text = existing {
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                if f.count >= 3 { byTime[String(f[0])] = "\(f[1])\t\(f[2])" }
            }
        }
        for s in new {
            byTime[timeFmt.string(from: s.time)] = "\(s.onAC ? "AC" : "Batt")\t\(s.percent)"
        }
        let body = byTime.keys.sorted().map { "\($0)\t\(byTime[$0]!)" }.joined(separator: "\n") + "\n"
        guard body != existing else { return false }
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - backfill

    /// How far history is known to be COMPLETE -- not how new the newest sample
    /// is. Persisted, because surviving a relaunch is the whole point.
    ///
    /// The distinction matters: a query that returns nothing still advances this,
    /// because we looked and there was nothing to find. Keying off the newest
    /// sample instead would leave a machine parked on AC at 100%, where `powerd`
    /// emits no change events at all, with a gap that never closes -- re-querying
    /// a widening window on every single open, which is the behaviour this is
    /// here to remove.
    private static let coverKey = "BackfillCoveredThrough"

    private var coveredThrough: Date? {
        get { UserDefaults.standard.object(forKey: HistoryStore.coverKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: HistoryStore.coverKey) }
    }

    /// Skip the query while coverage is this fresh. Three of the daemon's 300s
    /// cadences: slack for a late write or a slow wake, tight enough that a real
    /// gap is caught on the next open.
    private static let coverSlack: TimeInterval = 15 * 60

    /// Never ask for more than this in one go. Only bites on a first run, where
    /// there is no mark and the alternative is an unbounded window.
    private static let maxLookback: TimeInterval = 7 * 24 * 3600

    private static let rx = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\.\d+ .*Capacity:(\d+) Source:(AC|Batt)"#)

    private static let logPredicate =
        #"subsystem == "com.apple.powerd" AND category == "battery" "# +
        #"AND eventMessage CONTAINS "Battery capacity change""#

    /// Fold `powerd`'s charge events into the store, for the stretch the store
    /// does not already cover.
    ///
    /// This was `pmset -g log`, which takes no arguments: 13.8MB and ~3s of CPU
    /// for the whole week however little you wanted, with a reading on 2,057 of
    /// its 51,585 lines. `log show` takes `--start`, so the cost tracks the gap
    /// rather than the log -- 0.13s for a short catch-up -- and every line it
    /// returns is a reading, in one spelling instead of two.
    ///
    /// Runs off the main thread. `force` is the gear menu's "backfill now": that
    /// is someone asking explicitly, so it ignores the coverage mark.
    func backfill(force: Bool = false, completion: (() -> Void)? = nil) {
        // Captured BEFORE the query. An event logged while it runs must be read
        // again next time, not skipped: overlap is free, because writes are keyed
        // by timestamp and merge, whereas a gap is permanent.
        let asOf = Date()
        let mark = coveredThrough

        if !force, let m = mark, asOf.timeIntervalSince(m) < HistoryStore.coverSlack {
            completion?()
            return
        }

        let from = max(mark ?? .distantPast,
                       asOf.addingTimeInterval(-HistoryStore.maxLookback))
        // Formatted here rather than inside the closure: the formatters are lazy
        // vars and the main thread touches them too.
        let fromArg = logArgFmt.string(from: from)

        queue.async { [weak self] in
            guard let self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show",
                           "--start", fromArg,
                           "--predicate", HistoryStore.logPredicate,
                           "--style", "compact"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { DispatchQueue.main.async { completion?() }; return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            // A failed query leaves the mark alone: an unknown stretch is still
            // unknown, and advancing it would lose that stretch for good.
            guard p.terminationStatus == 0 else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let text = String(decoding: data, as: UTF8.self)

            var perDay: [String: [Sample]] = [:]
            for line in text.split(separator: "\n") {
                let s = String(line)
                let r = NSRange(s.startIndex..., in: s)
                guard let m = HistoryStore.rx.firstMatch(in: s, range: r),
                      let dR = Range(m.range(at: 1), in: s),
                      let tR = Range(m.range(at: 2), in: s),
                      let pR = Range(m.range(at: 3), in: s),
                      let sR = Range(m.range(at: 4), in: s),
                      let pct = Int(s[pR]) else { continue }
                let dayS = String(s[dR])
                guard let t = self.timestamp(dayS, String(s[tR])) else { continue }
                perDay[dayS, default: []].append(
                    Sample(time: t, onAC: s[sR] == "AC", percent: pct))
            }
            for (d, samples) in perDay { self.write(samples, into: d) }

            DispatchQueue.main.async {
                self.coveredThrough = asOf
                self.reload()
                completion?()
            }
        }
    }

    private func timestamp(_ dayS: String, _ timeS: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: "\(dayS) \(timeS)")
    }

    // MARK: - reading

    private func samples(for dayString: String) -> [Sample] {
        guard let text = try? String(contentsOf: file(dayString), encoding: .utf8) else { return [] }
        var out: [Sample] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t")
            guard f.count >= 3, let pct = Int(f[2]),
                  let t = timestamp(dayString, String(f[0])) else { continue }
            out.append(Sample(time: t, onAC: f[1] == "AC", percent: pct))
        }
        return out.sorted { $0.time < $1.time }
    }

    func reload() {
        let dayString = dayFmt.string(from: day)
        isLoading = true
        let pts = samples(for: dayString)
        appNameCache.removeAll()
        let fg = foregroundFromVitals(dayString)
        let who = foregroundLine(fg)
        let cpu = cpuHours(dayString, day: day, foreground: fg)
        cpuRecorded = cpu.recorded
        powerRecorded = VitalsStore.PowerDays.shared.day(dayString).rows.contains { $0.packageMw != nil }
        // Only interesting when coverage starts AFTER midnight -- that is the
        // case the header has to explain, because the hours above it carry no
        // line of their own any more.
        if let start = cpu.coverStart,
           start > Calendar.current.startOfDay(for: day) {
            cpuCoverFrom = start
        } else {
            cpuCoverFrom = nil
        }
        let draw = VitalsStore.DrawDays.shared.day(dayString)
        drawRecorded = draw.rows.contains { $0.systemMw != nil }
        let machine = machineMwByHour(draw)
        let devices = devicesByHour(dayString,
                                    screen: screenSecondsByHour(dayString),
                                    screenPoints: screenPointsByHour(draw))
        deviceRecorded = VitalsStore.DeviceDays.shared.day(dayString).recorded
        rows = buildRows(day: day, pts: pts, who: who, cpu: cpu,
                         machine: machine, devices: devices)
        chart = buildChart(day: day, pts: pts)
        summary = summarise(rows)
        availableDays = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".tsv") }
            .map { String($0.dropLast(4)) }
            .sorted()
        isLoading = false
    }

    /// Mean whole-machine draw per hour, in milliwatts.
    ///
    /// A plain mean of the readings that landed in the hour, and the arithmetic
    /// is only sound because `draw` rows are instantaneous and evenly spaced: an
    /// hour the daemon was only awake for ten minutes of reports what those ten
    /// minutes drew, not what the hour cost. `covered` is what stops that being
    /// read as the whole hour -- below forty readings the hour is dropped
    /// rather than averaged, because a machine that slept through most of it
    /// would otherwise report the draw of the few minutes it was up.
    private func machineMwByHour(_ draw: VitalsStore.DrawDayData) -> [Int: Int] {
        let cal = Calendar.current
        var acc: [Int: (sum: Int, n: Int)] = [:]
        for r in draw.rows {
            guard let mw = r.systemMw else { continue }
            let h = cal.component(.hour, from: r.time)
            var a = acc[h] ?? (0, 0)
            a.sum += mw; a.n += 1
            acc[h] = a
        }
        var out: [Int: Int] = [:]
        for (h, a) in acc where a.n >= 40 { out[h] = a.sum / a.n }
        return out
    }

    /// Seconds the screen was ON, per hour, from `activity`.
    ///
    /// Every `app` row is a stretch with the display awake -- including the ones
    /// named `(idle)` and `(switching)`, which is why this counts rows rather
    /// than app names. The display-off stretches are the `display_asleep` rows,
    /// and they are simply the gaps between these.
    private func screenSecondsByHour(_ dayString: String) -> [Int: Int] {
        guard let text = try? String(contentsOf: VitalsStore.activityDir
                                        .appendingPathComponent("\(dayString).tsv"),
                                     encoding: .utf8) else { return [:] }
        func secs(_ iso: String) -> Int? {
            guard let t = iso.split(separator: "T").last else { return nil }
            let p = t.split(separator: ":").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return p[0] * 3600 + p[1] * 60 + p[2]
        }
        let nowSecs: Int = {
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        }()
        var out: [Int: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, f[2] == "app", let a = secs(f[0]) else { continue }
            let b = f[1] == "(open)" ? nowSecs : (secs(f[1]) ?? nowSecs)
            guard b > a else { continue }
            var t = a
            while t < b {
                let h = t / 3600
                let nxt = min((h + 1) * 3600, b)
                out[h, default: 0] += nxt - t
                t = nxt
            }
        }
        return out
    }

    /// Hardware awake per hour: the screen, then everything `device` recorded,
    /// longest first.
    ///
    /// Devices of the same kind and name are summed across the hour's windows --
    /// `secs` is real on-time, so summing is the right operation and counting
    /// rows would be wrong.
    /// Points of battery the screen cost, per hour.
    ///
    /// `k` milliwatts per per-mille times the mean brightness over the minutes
    /// the panel was actually lit, times those minutes, divided by the watt-hours
    /// in one point of THIS battery. Rows where the panel slept carry "-" and are
    /// not in the mean, so a half-dark hour is charged for its lit half and not
    /// for an average of light and dark.
    ///
    /// A FITTED number sitting in a column of measured ones, which is why the
    /// row that shows it is marked. The brightness is read; the watts are not.
    private func screenPointsByHour(_ draw: VitalsStore.DrawDayData) -> [Int: Double] {
        guard let cal = ScreenCalibration.load(), let per = BatteryCapacity.whPerPoint(),
              per > 0 else { return [:] }
        let calendar = Calendar.current
        var acc: [Int: (sum: Int, n: Int)] = [:]
        for r in draw.rows {
            guard let pm = r.screenPerMille else { continue }
            let h = calendar.component(.hour, from: r.time)
            var a = acc[h] ?? (0, 0)
            a.sum += pm; a.n += 1
            acc[h] = a
        }
        var out: [Int: Double] = [:]
        for (h, a) in acc where a.n > 0 {
            // Rows are a minute apart, so their count is also the minutes they
            // speak for -- capped at the hour, the same arithmetic the chip's
            // own attribution uses one screen down.
            let hours = min(Double(a.n), 60) / 60
            let wh = cal.mwPerPerMille * (Double(a.sum) / Double(a.n)) / 1000 * hours
            out[h] = wh / per
        }
        return out
    }

    private func devicesByHour(_ dayString: String,
                               screen: [Int: Int],
                               screenPoints: [Int: Double]) -> [Int: [DeviceUse]] {
        let cal = Calendar.current
        var acc: [Int: [String: DeviceUse]] = [:]
        for r in VitalsStore.DeviceDays.shared.day(dayString).rows {
            let h = cal.component(.hour, from: r.time)
            let key = r.kind + "\u{0000}" + r.name
            var use = acc[h]?[key] ?? DeviceUse(kind: r.kind, name: r.name,
                                                seconds: 0, points: nil)
            use.seconds += Int(r.secs.rounded())
            acc[h, default: [:]][key] = use
        }
        var out: [Int: [DeviceUse]] = [:]
        for h in Set(acc.keys).union(screen.keys) {
            var list = (acc[h]?.values).map { Array($0) } ?? []
            list.sort { $0.seconds > $1.seconds }
            // The screen leads, always. It is on for most of most hours and it
            // is the largest draw in nearly all of them, so sorting it in by
            // duration alongside a four-second camera would bury the answer.
            if let s = screen[h], s > 0 {
                list.insert(DeviceUse(kind: "screen", name: "screen", seconds: s,
                                      points: screenPoints[h]), at: 0)
            }
            out[h] = list
        }
        return out
    }

    private func buildRows(day: Date, pts: [Sample], who: [Int: String],
                           cpu: CPUHours,
                           machine: [Int: Int],
                           devices: [Int: [DeviceUse]]) -> [HourRow] {
        guard let last = pts.last else { return [] }
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: day)
        let isToday = cal.isDateInToday(day)
        let end = isToday ? min(Date(), midnight.addingTimeInterval(86400)) : last.time
        guard end > midnight else { return [] }

        func charge(at t: Date) -> (Int, String) { Self.charge(at: t, in: pts) }

        var out: [HourRow] = []
        var h = midnight
        // Zero-padded ("01PM", not "1PM") so every label is the same width and the
        // column lines up instead of ragging left.
        let hourFmt = DateFormatter(); hourFmt.dateFormat = "hha"
        hourFmt.locale = Locale(identifier: "en_US_POSIX")
        let partFmt = DateFormatter(); partFmt.dateFormat = "hh:mma"
        partFmt.locale = Locale(identifier: "en_US_POSIX")
        func stamp(_ t: Date) -> String {
            let onTheHour = cal.component(.minute, from: t) == 0
            return (onTheHour ? hourFmt.string(from: t) : partFmt.string(from: t))
        }
        while h < end {
            let nxt = min(h.addingTimeInterval(3600), end)
            let (c1, _) = charge(at: h)
            let (c2, src) = charge(at: nxt)
            let hour = cal.component(.hour, from: h)
            let covered = pts.contains { $0.time >= h && $0.time <= nxt }
            // What the hour lost that no app can be held to. Only meaningful
            // while discharging: a charging hour has no drain to divide, and a
            // flat hour has nothing left over once the apps are counted.
            let lost = Double(c1 - c2)
            let attributed = cpu.attributedByHour[hour]
            let remainder: Double? = (lost > 0 && attributed != nil)
                ? max(0, lost - attributed!) : nil
            out.append(HourRow(hour: hour,
                               label: "\(stamp(h))–\(stamp(nxt))",
                               startPct: c1, endPct: c2, source: src,
                               measured: covered, who: who[hour] ?? "",
                               cpu: cpu.verdict(hour: hour, from: h, to: nxt),
                               systemPoints: remainder,
                               machineMw: machine[hour],
                               devices: devices[hour] ?? []))
            h = nxt
        }
        return out
    }

    /// Linear interpolation between the surrounding samples: the log only writes on
    /// power events, so whole hours carry no sample. Bucketing by "samples seen in
    /// this hour" would report those as 0% and dump their drain on a neighbour.
    static func charge(at t: Date, in pts: [Sample]) -> (Int, String) {
        guard let first = pts.first, let last = pts.last else { return (0, "Batt") }
        if t <= first.time { return (first.percent, first.onAC ? "AC" : "Batt") }
        if t >= last.time { return (last.percent, last.onAC ? "AC" : "Batt") }
        var lo = first, hi = last
        for s in pts { if s.time <= t { lo = s } else { hi = s; break } }
        let span = hi.time.timeIntervalSince(lo.time)
        let f = span > 0 ? t.timeIntervalSince(lo.time) / span : 0
        let pct = Int((Double(lo.percent) + Double(hi.percent - lo.percent) * f).rounded())
        let src = lo.onAC == hi.onAC
            ? (lo.onAC ? "AC" : "Batt")
            : (lo.onAC ? "AC->Batt" : "Batt->AC")
        return (pct, src)
    }

    /// One bar every 15 minutes -- fine enough to show a charge ramp, coarse enough
    /// that 96 bars still have air between them at this width.
    private func buildChart(day: Date, pts: [Sample]) -> [ChartPoint] {
        guard let last = pts.last else { return [] }
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: day)
        let end = cal.isDateInToday(day)
            ? min(Date(), midnight.addingTimeInterval(86400))
            : last.time
        var out: [ChartPoint] = []
        var t = midnight
        while t <= end {
            let (pct, src) = Self.charge(at: t, in: pts)
            out.append(ChartPoint(t: t, pct: pct, onAC: src.hasPrefix("AC")))
            t += 900
        }
        return out
    }

    private func summarise(_ rows: [HourRow]) -> DaySummary {
        var s = DaySummary()
        for r in rows {
            if r.delta < 0 { s.drained -= r.delta } else { s.charged += r.delta }
            if r.source.hasPrefix("Batt") { s.onBatteryHours += 1 }
        }
        s.worstHour = rows.min { $0.delta < $1.delta }
        return s
    }

    // MARK: - who was active (a proxy, not a measurement)

    /// The readable version of foreground time: the top three, over two minutes.
    private func foregroundLine(_ perHour: [Int: [String: Int]]) -> [Int: String] {
        perHour.mapValues { counts in
            counts.sorted { $0.value > $1.value }
                .prefix(3)
                .filter { $0.value >= 120 }
                .map { "\($0.key) \($0.value / 60)m" }
                .joined(separator: ", ")
        }
    }

    /// Seconds each app held the foreground, per hour, from the vitals activity
    /// stream.
    ///
    /// macOS keeps NO historical per-process power data -- nothing on the machine
    /// can say what drew watts at 11am. Foreground time is the closest available
    /// stand-in, and the Battery tab needs it twice: once for the line a person
    /// reads, and once to decide whose drawing WindowServer was doing. Kept as
    /// numbers rather than collapsed straight to a label for that reason. Absent
    /// stream = empty column, never a guess.
    private func foregroundFromVitals(_ dayString: String) -> [Int: [String: Int]] {
        guard let text = try? String(contentsOf: VitalsStore.activityDir
                                        .appendingPathComponent("\(dayString).tsv"),
                                     encoding: .utf8) else { return [:] }
        func secs(_ iso: String) -> Int? {
            guard let t = iso.split(separator: "T").last else { return nil }
            let p = t.split(separator: ":").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return p[0] * 3600 + p[1] * 60 + p[2]
        }
        let nowSecs: Int = {
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        }()

        var perHour: [Int: [String: Int]] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, f[2] == "app" else { continue }   // skip header and display_asleep
            guard let a = secs(f[0]) else { continue }
            // Only the last row may carry the sentinel, and it ends now.
            let b = f[1] == "(open)" ? nowSecs : (secs(f[1]) ?? nowSecs)
            guard b > a else { continue }
            let app = f[4].replacingOccurrences(of: "\u{200E}", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard app != "-", !app.isEmpty else { continue }
            var t = a
            while t < b {
                let h = t / 3600
                let nxt = min((h + 1) * 3600, b)
                perHour[h, default: [:]][app, default: 0] += nxt - t
                t = nxt
            }
        }
        return perHour
    }

    /// Foreground entries that name a real application.
    ///
    /// A parenthesised name such as `(idle)` or `(switching)` stands for a
    /// stretch with no app in front; it cannot be held responsible for drawing,
    /// and counting it would silently shrink everyone else's share.
    private static func realApps(_ counts: [String: Int]) -> [String: Int] {
        counts.filter { !$0.key.hasPrefix("(") && $0.value > 0 }
    }

    // MARK: - what was working hard (a measurement, unlike the column beside it)

    /// The cpu stream rolled up to the hour, plus the window it can answer for.
    ///
    /// The window is the whole reason this is a struct and not a dictionary. A
    /// missing hour inside it means nothing was busy; a missing hour outside it
    /// means nobody was recording. Only one of those is a fact about the CPU.
    struct CPUHours {
        /// The display name the compositor arrives under. Named once here
        /// rather than spelled in the middle of the arithmetic, because the
        /// whole attribution turns on this one string.
        static let compositor = "WindowServer"

        var recorded = false
        var byHour: [Int: [CPUShare]] = [:]
        /// Points attributed to ALL apps in the hour, not just the three shown.
        /// The remainder subtracts this, so it must not be the top-3 sum.
        var attributedByHour: [Int: Double] = [:]
        /// First and last moment the stream answers for. nil when it never ran.
        var coverStart: Date?
        var coverEnd: Date?

        func verdict(hour: Int, from: Date, to: Date) -> HourCPU {
            // Rows beat everything: if work was recorded, the hour is answered.
            if let list = byHour[hour], !list.isEmpty { return .busy(list) }
            guard recorded, let a = coverStart, let b = coverEnd else { return .notRecorded }
            // "Nothing was busy" is only honest for an hour recorded end to
            // end. A part-covered hour with no rows -- the hour the stream
            // started in, the hour the daemon died in -- says nothing.
            return (from >= a && to <= b) ? .idle : .notRecorded
        }
    }

    /// Read `cpu/<date>.tsv` and sum each process's cycles into its hour.
    ///
    /// Ranked on CYCLES and never on time: the cores on this machine run at
    /// 1.0-1.6GHz when they are efficiency cores and 3.2GHz when they are not,
    /// so equal milliseconds can be three times the work. `cpuMs` is carried
    /// alongside because it is the number a person recognises, and it is summed
    /// the same way rather than re-derived from cycles.
    ///
    /// Cost: one cold parse of the day file, at reload -- day change or panel
    /// open, never per redraw. `CPUDays` skips even that when the mtime has not
    /// moved, which is every reload on a past day.
    private func cpuHours(_ dayString: String, day: Date,
                          foreground: [Int: [String: Int]]) -> CPUHours {
        let data = VitalsStore.CPUDays.shared.day(dayString)
        var out = CPUHours(recorded: data.recorded)
        guard data.recorded else { return out }

        out.coverStart = data.firstSample
        out.coverEnd = data.lastSample
        // Today, with the daemon still writing, coverage runs to now: the last
        // row may be twenty minutes old simply because nothing has been busy
        // since, and that is an idle stretch rather than an unrecorded one.
        if Calendar.current.isDateInToday(day), case .live = VitalsStore.liveness() {
            out.coverEnd = Date()
        }

        let cal = Calendar.current
        var totals: [Int: [String: (cycles: Int64, ms: Int)]] = [:]
        for r in data.rows {
            let h = cal.component(.hour, from: r.time)
            // Keyed on the display name, not the pid: a program restarted
            // mid-hour is still that program, and a pid is not even a stable
            // name for one process across a day (CONTRACT §5).
            var acc = totals[h]?[r.process] ?? (0, 0)
            acc.cycles += r.cycles
            acc.ms += r.cpuMs
            totals[h, default: [:]][r.process] = acc
        }
        // ---- turn work into battery points ------------------------------
        //
        // Three inputs, and only the first is measured:
        //
        //   chip watt-hours   avg(package_mw) over the hour x the hours covered
        //   app's share       its own cycles, PLUS its share of WindowServer's
        //   points per Wh     this battery's own full-charge capacity
        //
        // WindowServer is the reason this function is not a sort. It is
        // routinely the single biggest consumer on the machine -- a quarter of
        // all cycles on the day this was written -- and it is nobody's app: it
        // draws for whatever is on screen. Left alone it takes the top slot in
        // every row and answers nothing. So its cycles are handed to the apps
        // that held the foreground, in proportion to how long they held it.
        //
        // That is a CORRELATION and it is marked as one in the UI. It holds
        // because drawing tracks the visible window. It is applied to nothing
        // else: mediaanalysisd, mobileassetd and mds run precisely when nobody
        // is there, so splitting them by "what was in front" would blame
        // whatever window happened to be open during lunch. They stay in the
        // remainder, which is the honest place for them.
        let power = VitalsStore.PowerDays.shared.day(dayString)
        let whPerPoint = BatteryCapacity.whPerPoint()
        let cal2 = Calendar.current
        var mwByHour: [Int: (sum: Int, n: Int)] = [:]
        for r in power.rows {
            guard let mw = r.packageMw else { continue }
            let h = cal2.component(.hour, from: r.time)
            var acc = mwByHour[h] ?? (0, 0)
            acc.sum += mw; acc.n += 1
            mwByHour[h] = acc
        }

        for (h, procs) in totals {
            let totalCycles = procs.values.reduce(Int64(0)) { $0 + $1.cycles }
            guard totalCycles > 0 else { continue }

            // WindowServer's work, redistributed by foreground time.
            let wsCycles = procs[CPUHours.compositor]?.cycles ?? 0
            let fgApps = Self.realApps(foreground[h] ?? [:])
            let fgTotal = fgApps.values.reduce(0, +)
            var drawn: [String: Int64] = [:]
            if wsCycles > 0, fgTotal > 0 {
                for (app, secs) in fgApps {
                    drawn[app] = Int64(Double(wsCycles) * Double(secs) / Double(fgTotal))
                }
            }

            // An app is a thing with a bundle; everything else is the system.
            // Chrome's forty helpers already arrive under one name, because the
            // daemon resolves display names up to the outermost .app.
            var shares: [CPUShare] = []
            var attributed: Double = 0
            let names = Set(procs.keys).union(drawn.keys)

            // The hour's measured chip energy, in points of THIS battery.
            var chipPoints: Double?
            if let acc = mwByHour[h], acc.n > 0, let per = whPerPoint, per > 0 {
                // Rows are one-second bursts a minute apart, so their count is
                // also the minutes they speak for -- capped at the hour.
                let hours = min(Double(acc.n), 60) / 60
                let wh = (Double(acc.sum) / Double(acc.n)) / 1000 * hours
                chipPoints = wh / per
            }

            for name in names {
                let own = self.isApplication(name, day: dayString, hour: h) ? (procs[name]?.cycles ?? 0) : 0
                let cycles = own + (drawn[name] ?? 0)
                guard cycles > 0 else { continue }
                let ms = procs[name]?.ms ?? 0
                let pts = chipPoints.map { $0 * Double(cycles) / Double(totalCycles) }
                if let p = pts { attributed += p }
                shares.append(CPUShare(name: name, cycles: cycles, cpuMs: ms,
                                       points: pts,
                                       includesDrawing: (drawn[name] ?? 0) > 0))
            }

            // Eight, not three: the hour row folds open and the apps below
            // the first one are the whole reason it folds. Three left an
            // open hour with two rows in it. The cap still exists because
            // the tail is dozens of processes at a thousandth of a point.
            // `attributed` above is summed over ALL of them, so the
            // remainder does not move when this number does.
            out.byHour[h] = shares.sorted { $0.cycles > $1.cycles }.prefix(8).map { $0 }
            out.attributedByHour[h] = attributed
        }
        return out
    }

    /// Is this display name an application rather than a system service?
    ///
    /// Answered from the executable path in `proc/<date>.tsv`: a path containing
    /// `.app/` is something a person launched and can close. `duetexpertd` and
    /// `mobileassetd` are not, and letting them compete for one of three slots
    /// in the battery table would push out the row that answers the question.
    ///
    /// Unknown paths are treated as NOT an app. A pid the daemon could not
    /// resolve is more likely a short-lived system process than a missing
    /// application, and the failure that matters here is putting a service at
    /// the top of the table.
    private func isApplication(_ name: String, day: String, hour: Int) -> Bool {
        if let cached = appNameCache[name] { return cached }
        let rows = VitalsStore.CPUDays.shared.day(day).rows
        var verdict = false
        for r in rows where r.process == name {
            if let path = VitalsStore.NetPaths.shared.path(pid: r.pid, at: r.time) {
                verdict = path.contains(".app/")
                break
            }
        }
        appNameCache[name] = verdict
        return verdict
    }

    // MARK: - navigation helpers

    func step(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }
    var canGoForward: Bool { !Calendar.current.isDateInToday(day) && day < Date() }
    var earliestDay: Date {
        guard let s = availableDays.first, let d = dayFmt.date(from: s) else { return day }
        return d
    }
}
