import Foundation
import AppKit
import Combine

// =============================================================================
// NetStore -- the Net tab's data, read from the vitalsd store.
//
//     vitalsd  --(records continuously, 12s idle / 2s watched)-->  the store
//     NetStore --(reads a window of it, joins names)-->  NetSnapshot  --> NetView
//
// This file used to own sampling: it drove the NetworkStatistics framework,
// accumulated deltas in memory, and everything it knew died when the dropdown
// closed. The daemon does that now, so what is left is a reader -- and the
// rewrite deleted three problems rather than moving them:
//
//   * THE BLANK OPEN IS GONE. Counts used to start at zero on every open and a
//     glance shorter than ~4s showed nothing. The window below is read from
//     disk, so the table is populated the instant the panel appears.
//   * THE PANEL NO LONGER DECIDES WHAT IS RECORDED. Sampling continues whether
//     anyone is looking or not, so a row cannot be missed for having been
//     unobserved.
//   * A DEAD PRODUCER IS VISIBLE. `.unavailable` says so in words. An empty
//     table and a stopped daemon used to render identically, which is the one
//     failure this design can cause silently.
//
// Public surface is unchanged -- `start()`, `stop()`, `snapshot`, `observe` --
// so NetView did not move. `start()`/`stop()` no longer mean "sample"; they mean
// "ask the daemon for the fast rate and subscribe", which is why they still
// bracket the dropdown being open.
// =============================================================================

protocol NetSnapshotStream: AnyObject {
    /// Returns a cancel closure. Calling it unsubscribes; dropping it does not.
    func observe(_ onChange: @escaping () -> Void) -> () -> Void
}

final class NetStore: ObservableObject, NetSnapshotProvider, NetSnapshotStream {

    static let shared = NetStore()

    // MARK: - Which day

    /// The Net tab is a daily report, navigated exactly like the Battery tab:
    /// back and forward a day at a time, a calendar, and a "Today" link.
    ///
    /// It used to be four rolling windows (15m / 1h / 6h / Today). The windows
    /// answered "what is it doing right now"; a day answers "what did it do",
    /// which is the question the store can now actually support -- the daemon
    /// records continuously, so every one of the 14 days it keeps is as
    /// readable as the current one. The cost, stated plainly: there is no
    /// longer a way to narrow to the last fifteen minutes. Today's view is
    /// live and updates as bytes arrive, so "right now" is still visible at
    /// the right-hand end of the chart -- just not isolated from the rest of
    /// the day.
    ///
    /// Not persisted, and reset to today on every open. That is what the
    /// Battery tab does, and a panel that reopens on a day three weeks ago
    /// because that is where you left it is a panel that looks broken.
    @Published var day: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard !Calendar.current.isDate(day, inSameDayAs: oldValue) else { return }
            lastRead = nil
            pastDay = nil
            reader.reset()
            refreshWatcher()
            invalidate()
        }
    }

    var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// Days the store actually holds, oldest first. Read from the filenames,
    /// so a day the daemon never wrote is not offered.
    private(set) var availableDays: [String] = []

    var earliestDay: Date {
        guard let first = availableDays.first,
              let d = VitalsStore.dayDate(first) else { return day }
        return min(d, day)
    }

    /// Forward stops at today. There is nothing after it and a chevron that
    /// does nothing is worse than one that is visibly disabled.
    var canGoForward: Bool { !isToday && day < Date() }

    func step(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }

    /// How often a redraw may re-read. Today is live at the daemon's watched
    /// rate; a past day cannot change, so it is read once and never again.
    private var minReadInterval: TimeInterval { isToday ? 2 : .infinity }

    private var open = false
    private var watcherTimer: Timer?
    private var notify = VitalsNotify()
    private var lastRead: Date?
    private var cached: NetSnapshot?
    /// Follows the day files by byte offset instead of re-parsing them. Lives
    /// only between open and close, like everything else here.
    private let reader = NetReader()
    /// One past day, parsed once. Past days are immutable -- the daemon only
    /// ever appends to the current one -- so re-reading them is pure waste.
    private var pastDay: (key: String, rows: [VitalsStore.NetRow])?
    /// Today's last minute, for the live rate in the header. Separate from
    /// `reader` because that one follows whichever day is on screen, and the
    /// rate readout is about now regardless of what you are looking at.
    private let liveReader = NetReader()
    private var observers: [Int: () -> Void] = [:]
    private var nextObserverID = 0

    private init() {}

    var isRunning: Bool { open }

    // MARK: - Lifecycle (dropdown open/close)

    func start() {
        guard !open else { return }
        open = true
        day = Calendar.current.startOfDay(for: Date())
        availableDays = VitalsStore.netDays()
        refreshWatcher()

        notify.subscribe(key: VitalsNotify.netKey) { [weak self] in
            // `open` is checked as well as unsubscribing in stop(). Belt and
            // braces on purpose: when this callback survived a dismissal it
            // re-parsed the whole window every 2s behind a panel nobody could
            // see, and the only symptom was a number in Activity Monitor.
            guard let self, self.open else { return }
            self.invalidate()
        }
        invalidate()
    }

    func stop() {
        guard open else { return }
        open = false
        watcherTimer?.invalidate()
        watcherTimer = nil
        notify.unsubscribe()
        VitalsStore.dropWatcher()      // back to the slow rate immediately
        cached = nil
        lastRead = nil
        pastDay = nil
        reader.reset()                 // nothing retained behind a shut dropdown
        liveReader.reset()
        notifyObservers()
    }

    /// The panel no longer asks the daemon to sample faster. At all.
    ///
    /// The 2s claim was built for a rolling 15-minute window drawn at 15-second
    /// buckets, where the extra resolution was the whole point. This pane is a
    /// daily report and its chart buckets are FIFTEEN MINUTES wide -- 12s
    /// sampling is already seventy-five times finer than anything it can draw,
    /// and the per-app totals do not care at all. So the claim bought nothing
    /// and cost a great deal: measured here, the daemon at the watched rate ran
    /// at 3.1% against roughly 0.5% idle, wrote six times the rows, and woke
    /// this app to re-render the whole table every two seconds instead of every
    /// twelve. Removing it is the single biggest saving available on either
    /// side, and nothing on screen is worse for it.
    ///
    /// `dropWatcher` stays on `stop()` as hygiene: an older build, or one that
    /// crashed mid-session, may have left a lease behind.
    private func refreshWatcher() {
        watcherTimer?.invalidate()
        watcherTimer = nil
        if open { VitalsStore.dropWatcher() }
    }

    // MARK: - Observation

    func observe(_ onChange: @escaping () -> Void) -> () -> Void {
        let id = nextObserverID
        nextObserverID += 1
        observers[id] = onChange
        return { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    private func invalidate() {
        cached = nil
        notifyObservers()
    }

    private func notifyObservers() {
        objectWillChange.send()
        for cb in observers.values { cb() }
    }

    // MARK: - The snapshot

    var snapshot: NetSnapshot {
        let now = Date()
        if let c = cached, let t = lastRead, now.timeIntervalSince(t) < minReadInterval {
            return c
        }
        let built = build(now: now)
        cached = built
        lastRead = now
        return built
    }

    /// Every row of the selected day.
    ///
    /// Today comes from the incremental reader, so a refresh parses only what
    /// the daemon appended. A past day is read cold, once, and held -- at ~1.4MB
    /// and ~24k rows that is a couple of hundred milliseconds on the day you
    /// navigate to it and nothing at all thereafter.
    private func dayRows(now: Date) -> [VitalsStore.NetRow] {
        let midnight = Calendar.current.startOfDay(for: day)
        if isToday {
            return reader.rows(window: max(now.timeIntervalSince(midnight), 1), now: now)
        }
        let key = VitalsStore.dayKey(day)
        if let cachedDay = pastDay, cachedDay.key == key { return cachedDay.rows }
        let rows = VitalsStore.readNetDay(key)
        pastDay = (key, rows)
        return rows
    }

    /// Bytes per second over the last minute of TODAY, whatever day is on
    /// screen. The Battery tab's header shows the live charge while you page
    /// through history; this is the same idea, and the same reason -- what the
    /// machine is doing now does not stop being worth knowing because you are
    /// reading Tuesday.
    private func liveRate(now: Date) -> Double {
        let rows = liveReader.rows(window: 60, now: now)
        guard !rows.isEmpty else { return 0 }
        let bytes = rows.reduce(Int64(0)) { $0 + $1.rx + $1.tx }
        return Double(bytes) / 60
    }

    private func build(now: Date) -> NetSnapshot {
        let liveness = VitalsStore.liveness(now: now)

        // A dead producer is not a quiet machine. Say so before anything else.
        if let message = liveness.message {
            return NetSnapshot(phase: .unavailable(message),
                               elapsed: 0, interval: 0, ticks: [], flows: [],
                               talkers: [], destinations: [], hostCount: 0,
                               noPeerDown: 0, noPeerUp: 0,
                               day: day, liveBytesPerSecond: 0)
        }

        let midnight = Calendar.current.startOfDay(for: day)
        // Today is only as long as it has got so far; a past day is 24 hours,
        // even the ones the Mac slept through. The chart's axis is the whole
        // day either way -- see NetDayChartView -- so this figure is only used
        // for the day's average, never for the drawing.
        let covered = isToday ? max(now.timeIntervalSince(midnight), 1) : 86_400
        let rows = dayRows(now: now)

        guard !rows.isEmpty else {
            return NetSnapshot(phase: .empty,
                               elapsed: covered, interval: NetStore.bucket,
                               ticks: [], flows: [], talkers: [], destinations: [],
                               hostCount: 0, noPeerDown: 0, noPeerUp: 0,
                               day: day, liveBytesPerSecond: liveRate(now: now))
        }

        return NetSnapshot(phase: .live,
                           elapsed: covered,
                           interval: NetStore.bucket,
                           ticks: ticks(rows, midnight: midnight),
                           flows: flows(rows),
                           talkers: [],      // derived from flows; see NetSnapshot
                           destinations: [],
                           hostCount: Set(rows.compactMap(\.remote)).count,
                           noPeerDown: rows.filter { $0.remote == nil }.reduce(0) { $0 + $1.rx },
                           noPeerUp: rows.filter { $0.remote == nil }.reduce(0) { $0 + $1.tx },
                           day: day,
                           liveBytesPerSecond: liveRate(now: now))
    }

    /// Chart resolution: 96 buckets of 15 minutes, one whole day.
    ///
    /// The same slot size the Battery chart samples at, so the two charts under
    /// the two tabs describe time at the same granularity and a spike in one
    /// can be lined up against the other by eye.
    static let bucket: TimeInterval = 900

    // MARK: - Rollups

    /// One row per (app, destination) pair -- what the tree draws.
    ///
    /// Grouped on the process NAME rather than the pid, because the daemon
    /// records across restarts: the same app can appear under several pids
    /// inside one window, and a person reading this wants one Chrome.
    private func flows(_ rows: [VitalsStore.NetRow]) -> [NetFlow] {
        struct Key: Hashable { let app: String; let remote: String? }
        // pid and seen ride along for the signature lookup: the LAST pid to
        // move bytes for this pair, and when. Latest wins because it is the one
        // most likely still alive, and an alive pid is the only kind whose
        // signature can be read at all.
        // One sysctl for the whole table, not one per row. `exited` below is a
        // LIVE fact -- it is about the machine now, not about the day being
        // read -- so it is recomputed with the snapshot rather than parsed out
        // of the store, which knows only that bytes moved.
        let running = RunningProcesses.snapshot()
        var agg: [Key: (down: Int64, up: Int64, pid: pid_t, seen: Date, alive: Bool)] = [:]
        for r in rows {
            let k = Key(app: r.process.isEmpty ? "pid \(r.pid)" : r.process, remote: r.remote)
            var e = agg[k] ?? (0, 0, r.pid, r.time, false)
            e.down += r.rx
            e.up += r.tx
            if r.time >= e.seen { e.pid = r.pid; e.seen = r.time }
            // ANY pid behind this pair still being the same live process is
            // enough. A row aggregates many sightings and several pids; one
            // survivor means the thing that moved these bytes is still here.
            if !e.alive, running.isSameProcess(pid: r.pid, asOf: r.time) { e.alive = true }
            agg[k] = e
        }

        return agg.map { key, v in
            let destination: String
            let detail: String
            let state: NetNameState

            if let address = key.remote {
                if let named = VitalsStore.Names.shared.name(for: address) {
                    destination = named
                    detail = address
                    state = Self.plainLabels.contains(named) ? .local : .named
                } else {
                    // The daemon resolves asynchronously, so an address it has
                    // not reached yet is pending, not unknown -- and either way
                    // the address itself never reaches the column.
                    destination = "Resolving\u{2026}"
                    detail = address
                    state = .resolving
                }
            } else {
                destination = "No destination"
                detail = "broadcast, multicast or a socket that never connected"
                state = .local
            }

            return NetFlow(id: "\(key.app)|\(key.remote ?? "-")",
                           app: key.app,
                           appDetail: key.app,
                           destination: destination,
                           destinationDetail: detail,
                           down: v.down, up: v.up,
                           state: state,
                           exited: !v.alive,
                           pid: v.pid,
                           lastSeen: v.seen)
        }
        .filter { $0.total > 0 }
        .sorted { $0.total == $1.total ? $0.app < $1.app : $0.total > $1.total }
    }

    /// Plain-word labels the daemon writes for ranges with no owner to look up.
    /// They are names, not failures, so they read as `.local`.
    private static let plainLabels: Set<String> = [
        "This Mac", "Device on your network", "Tailscale peer",
        "Link-local", "Multicast group", "No destination",
    ]

    // `talkers` used to be a second full pass over every row of the day to
    // produce numbers `flows` had already computed. At 16,819 rows that was
    // 1.41ms of the 7.2ms a rebuild costs, spent twice over. The totals now
    // come off `flows` in NetSnapshot and the pass is gone.

    /// Bytes per bucket across the window.
    ///
    /// Empty buckets are emitted as zeros rather than skipped: a gap in the
    /// sparkline should mean the machine was quiet, and dropping the bucket
    /// would instead compress time and make a quiet stretch invisible.
    private func ticks(_ rows: [VitalsStore.NetRow], midnight: Date) -> [NetTick] {
        let count = Int(86_400 / NetStore.bucket)        // 96
        var down = [Int64](repeating: 0, count: count)
        var up = [Int64](repeating: 0, count: count)

        for r in rows {
            let offset = r.time.timeIntervalSince(midnight)
            guard offset >= 0 else { continue }
            let i = min(Int(offset / NetStore.bucket), count - 1)
            down[i] += r.rx
            up[i] += r.tx
        }
        return (0..<count).map { NetTick(id: $0, down: down[$0], up: up[$0]) }
    }
}
