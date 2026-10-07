import Foundation
// notify.h is NOT re-exported by Foundation or by the Darwin module -- it has
// its own SDK modulemap. Without this line notify_register_dispatch is "not in
// scope" and this consumer silently falls back to never being told anything.
import notify

// =============================================================================
// VitalsStore -- read-only access to the store written by the vitalsd daemon.
//
// This app used to sample the network itself: it bound the private
// NetworkStatistics framework, ran whois and dig subprocesses to name what it
// found, and could only ever show what moved while its dropdown happened to be
// open. All of that now belongs to `vitalsd` (github.com/ktutnik/vitals), which records
// continuously, and this file is the whole of what replaced it: a reader.
//
// Three consequences worth knowing, because they change what the UI can say:
//
// 1. THERE IS HISTORY NOW. The panel no longer starts empty and climb from
//    nothing; it opens onto whatever the daemon already recorded. The four
//    blank seconds at the start of every open are gone, and so is the reason
//    they existed.
//
// 2. THE APP NO LONGER OBSERVES ITSELF. whois and dig ran in-process, so this
//    app's own lookups used to appear in its own table, with ARIN and RIPE as
//    destinations. The daemon does the resolving now and its subprocesses are
//    attributed to it.
//
// 3. A MISSING DAEMON MUST BE VISIBLE. An empty table and a dead producer
//    render identically unless something insists they do not, and the failure
//    is silent by nature. `liveness()` exists for exactly this, and NetView
//    draws `.unavailable` in words rather than showing a quiet machine.
//
// Store contract: vitals docs/CONTRACT.md (github.com/ktutnik/vitals). The parts this file
// relies on:
//   net/<date>.tsv     time secs pid process proto remote rport iface rx tx
//   proc/<date>.tsv    started pid path      (started is a FULL local ISO stamp)
//   names.tsv          prefix name source resolved_at
//   battery/<date>.tsv time source percent   (no header, 3 columns)
//   cpu/<date>.tsv     time pid process cycles cpu_ms wakeups
//   vitalsd.state      last_write marker
//
// The store now has TWO writers: vitalsd, which runs as the user, and
// vitals-helper, which runs as root and owns cpu/ and proc/. Nothing here needs
// to care which wrote a file -- one writer per file, and every file is handed
// back to the user -- except in one way: if the helper is not installed, cpu/
// and proc/ simply do not fill, and this file must treat that as "no data"
// rather than "the daemon is dead".
// =============================================================================

enum VitalsStore {

    static let root: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Vitals", isDirectory: true)

    static var netDir: URL { root.appendingPathComponent("net", isDirectory: true) }
    static var procDir: URL { root.appendingPathComponent("proc", isDirectory: true) }
    static var batteryDir: URL { root.appendingPathComponent("battery", isDirectory: true) }
    static var cpuDir: URL { root.appendingPathComponent("cpu", isDirectory: true) }
    static var powerDir: URL { root.appendingPathComponent("power", isDirectory: true) }
    static var drawDir: URL { root.appendingPathComponent("draw", isDirectory: true) }
    static var deviceDir: URL { root.appendingPathComponent("device", isDirectory: true) }
    static var activityDir: URL { root.appendingPathComponent("activity", isDirectory: true) }
    static var namesFile: URL { root.appendingPathComponent("names.tsv") }
    static var stateFile: URL { root.appendingPathComponent("vitalsd.state") }
    static var watchersDir: URL { root.appendingPathComponent("watchers", isDirectory: true) }

    // MARK: - Is the daemon alive?

    enum Liveness {
        /// Recording. `lastWrite` is how long ago it last touched the store.
        case live(lastWrite: TimeInterval)
        /// The store exists but nothing has written to it recently.
        case stale(lastWrite: TimeInterval)
        /// No store at all -- the daemon has never run here.
        case missing

        /// Words for the UI. Never "no data": that is the lie this type exists
        /// to prevent.
        var message: String? {
            switch self {
            case .live: return nil
            case .missing:
                return "vitals is not running.\nNothing is recording, so there is nothing to show."
            case .stale(let age):
                let mins = Int(age / 60)
                return "vitals has not recorded for \(mins) minute\(mins == 1 ? "" : "s").\nThe daemon may have stopped."
            }
        }
    }

    /// A write older than this means the daemon is not doing its job. The slow
    /// sampling rate is 12s, so a minute is four missed intervals -- late enough
    /// to be real, early enough to notice.
    private static let staleAfter: TimeInterval = 60

    static func liveness(now: Date = Date()) -> Liveness {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: stateFile.path),
              let modified = attrs[.modificationDate] as? Date else {
            return .missing
        }
        let age = now.timeIntervalSince(modified)
        return age <= staleAfter ? .live(lastWrite: age) : .stale(lastWrite: age)
    }

    // MARK: - Asking for the fast sampling rate

    /// The daemon samples every 12s until a consumer asks for better, then 2s
    /// (contract §4.3). Interest is a file whose mtime is refreshed; it decays
    /// after 30s, so a consumer that crashes cannot pin the fast rate forever.
    /// Call while the dropdown is open, stop calling when it closes -- there is
    /// nothing to clean up, which is the point of it decaying.
    static func touchWatcher(stream: String = "net", consumer: String = "sysmonitor") {
        let dir = watchersDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(stream).\(consumer)-\(getpid())")
        if !FileManager.default.createFile(atPath: f.path, contents: nil) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        }
    }

    /// Remove our own watcher rather than waiting out the decay, so closing the
    /// panel drops the daemon back to the slow rate immediately.
    /// Every lease this app has ever left behind, not just this run's.
    ///
    /// The name carries the pid, so a run that was killed rather than quit --
    /// `install.sh` does exactly that -- leaves a file nothing ever removes. It
    /// is harmless, because the mtime IS the lease and a frozen one expires,
    /// but it is litter in a directory whose whole value is that `ls -l` tells
    /// you who is watching. This app no longer claims the fast rate at all, so
    /// any `<stream>.sysmonitor-*` found here is by definition stale.
    static func dropWatcher(stream: String = "net", consumer: String = "sysmonitor") {
        let dir = watchersDir
        let prefix = "\(stream).\(consumer)-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Reading the net stream

    /// One row of net/<date>.tsv.
    struct NetRow {
        let time: Date
        /// The interval this delta covers. NOT optional and NOT inferable from
        /// the previous row's timestamp: the daemon switches between 2s and 12s,
        /// and inference breaks across a gap, a restart, and the exact moment
        /// the rate changes -- which is when the numbers matter most.
        let secs: Double
        let pid: pid_t
        let process: String
        /// nil for a socket with no peer (broadcast, multicast, unconnected UDP).
        /// The daemon writes "-"; those rows carry real bytes and dropping them
        /// would make every per-process rollup quietly wrong.
        let remote: String?
        let rx: Int64
        let tx: Int64
    }

    /// Rows written within `window` of now, oldest first.
    ///
    /// Reads at most two day files, because a window that starts before midnight
    /// spans yesterday's. Anything longer is not what this panel is for.
    ///
    /// This is the COLD read: it parses both files from the top. `NetReader`
    /// wraps it for the live panel, where re-parsing a whole day once a second
    /// to redraw fifteen minutes is the waste worth removing.
    static func readNet(window: TimeInterval, now: Date = Date()) -> [NetRow] {
        let cutoff = now.addingTimeInterval(-window)
        var rows: [NetRow] = []
        for day in dayKeys(from: cutoff, to: now) {
            let url = netDir.appendingPathComponent("\(day).tsv")
            guard let data = try? Data(contentsOf: url) else { continue }
            rows.append(contentsOf: parseNet(data, day: day, cutoff: cutoff, now: now))
        }
        return rows.sorted { $0.time < $1.time }
    }

    /// Parse whole lines out of one day file's bytes.
    ///
    /// Takes `Data` rather than `String` so the incremental reader can hand it a
    /// slice starting at a known byte offset; splitting on the newline byte is
    /// safe for UTF-8 because a continuation byte is never 0x0A.
    fileprivate static func parseNet(_ data: Data, day: String,
                                     cutoff: Date, now: Date) -> [NetRow] {
        guard let midnight = midnightFor(day: day) else { return [] }
        var out: [NetRow] = []
        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
            if line.hasPrefix("time\t") { continue }              // header
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            // EXACTLY ten. A row with more has been torn: the store is
            // appended to by another process, and a write interrupted at the
            // wrong moment leaves a line with the next row fused onto it.
            // Such a line parses "successfully" into nonsense -- a pid in
            // the address column, a timestamp welded to an IP -- which then
            // reaches the UI as a destination that can never be named, and
            // sits there saying "Resolving…" forever because nothing is
            // pending. Rejecting the row is the only honest option: the
            // bytes it should have contained are gone.
            guard f.count == 10 else { continue }
            guard let t = clockTime(String(f[0]), on: midnight), t >= cutoff, t <= now else { continue }
            let remoteRaw = String(f[5])
            // A remote is "-" or an address. Anything else is a torn line
            // that happened to keep its column count.
            if remoteRaw != "-" && !remoteRaw.isEmpty,
               IPPrefix.parseAddress(remoteRaw) == nil { continue }
            out.append(NetRow(time: t,
                              secs: Double(f[1]) ?? 12,
                              pid: pid_t(f[2]) ?? 0,
                              process: String(f[3]),
                              remote: (remoteRaw == "-" || remoteRaw.isEmpty) ? nil : remoteRaw,
                              rx: Int64(f[8]) ?? 0,
                              tx: Int64(f[9]) ?? 0))
        }
        return out
    }

    /// Every row of one day file, oldest first. Used for a past day, which
    /// cannot change and so is read exactly once.
    static func readNetDay(_ day: String) -> [NetRow] {
        guard let midnight = midnightFor(day: day),
              let data = try? Data(contentsOf: netDir.appendingPathComponent("\(day).tsv"))
        else { return [] }
        return parseNet(data, day: day,
                        cutoff: midnight,
                        now: midnight.addingTimeInterval(86_400))
            .sorted { $0.time < $1.time }
    }

    /// Days the net store holds, oldest first, from the filenames.
    static func netDays() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: netDir.path)) ?? [])
            .filter { $0.hasSuffix(".tsv") }
            .map { String($0.dropLast(4)) }
            .filter { dayFormatter.date(from: $0) != nil }
            .sorted()
    }

    static func dayDate(_ key: String) -> Date? { dayFormatter.date(from: key) }

    // MARK: - Reading the battery stream

    /// `battery/<date>.tsv` is byte-identical to this app's own former store --
    /// no header, `HH:MM:SS<TAB>source<TAB>percent` -- so the battery side of
    /// the cutover is a path change and nothing more.
    static func batteryFile(for day: String) -> URL {
        batteryDir.appendingPathComponent("\(day).tsv")
    }

    static func hasBattery(day: String) -> Bool {
        FileManager.default.fileExists(atPath: batteryFile(for: day).path)
    }

    // MARK: - Reading the cpu stream

    /// One row of `cpu/<date>.tsv` (vitals CONTRACT.md §5).
    ///
    /// THIS IS CPU WORK, NOT ENERGY. Nothing here is in joules and nothing here
    /// can be turned into joules. The contract spells out why at length: the one
    /// field in `proc_pid_rusage` that sounds like attributed energy
    /// (`ri_billed_energy`) reads zero for 86% of running processes and sums to
    /// a thousandth of what the machine actually draws, so the daemon does not
    /// record it. The stream is called `cpu` for that reason and every label
    /// this app puts on it must say the same word.
    struct CPURow {
        let time: Date
        let pid: pid_t
        /// The display name, and -- as in the net stream -- the authority on
        /// which program this is. Pids recycle; two rows sharing one pid on the
        /// same day may be two different programs.
        let process: String
        /// Delta of `ri_cycles` over the 60s interval. THE RANKING METRIC: the
        /// cores here are not interchangeable (3.2GHz performance against
        /// 1.0-1.6GHz efficiency measured the same day), so equal `cpuMs` can
        /// mean 3x the work done and wall time cannot see the difference.
        let cycles: Int64
        /// Delta of user+system time in real milliseconds. The human-readable
        /// figure -- what everything else on the machine shows.
        let cpuMs: Int
        /// Package idle wakeups. Recorded by the daemon, displayed by nobody yet.
        let wakeups: Int
    }

    /// What `cpu/<date>.tsv` has to say about one day.
    ///
    /// `recorded` is the distinction the Battery tab turns into words. A day
    /// with no file is not a day on which nothing ran -- it is a day nobody was
    /// watching, which is the case for every day before this stream existed and
    /// every day older than its 14-day retention, while the battery curve beside
    /// it is kept forever.
    struct CPUDayData {
        /// The file exists. False means the stream was not recording at all.
        let recorded: Bool
        /// Oldest first.
        let rows: [CPURow]
        /// The daemon baselines on its first sweep and emits nothing, so the
        /// first row is the first moment this day is answered for.
        var firstSample: Date? { rows.first?.time }
        var lastSample: Date? { rows.last?.time }
    }

    /// `cpu/<date>.tsv`, one day at a time, reloaded only when the file's mtime
    /// moves -- the same shape as `NetPaths`, and for the same two reasons:
    /// the Battery tab draws one day at a time, and today's file is appended to
    /// while the panel is open.
    ///
    /// The cold read is ~14,000 rows on a full day. It happens when the day
    /// changes or the panel opens, never per redraw, and never while the
    /// dropdown is shut.
    final class CPUDays {
        static let shared = CPUDays()

        private var loadedDay: String?
        private var loadedStamp: Date?
        private var cached = CPUDayData(recorded: false, rows: [])
        private let lock = NSLock()

        private init() {}

        func day(_ key: String) -> CPUDayData {
            let url = VitalsStore.cpuDir.appendingPathComponent("\(key).tsv")
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            lock.lock()
            if loadedDay == key, stamp == loadedStamp { defer { lock.unlock() }; return cached }
            lock.unlock()

            var rows: [CPURow] = []
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists, let midnight = VitalsStore.midnightFor(day: key),
               let data = try? Data(contentsOf: url) {
                for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
                    if line.hasPrefix("time\t") { continue }              // header
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    // EXACTLY six, for the reason parseNet insists on exactly
                    // ten: the daemon appends from another process and a line
                    // caught mid-write fuses the next row onto this one. Such a
                    // line still parses -- into a process named after a pid and
                    // a cycle count off by orders of magnitude -- and would then
                    // win the hour's ranking on nonsense.
                    guard f.count == 6,
                          let t = VitalsStore.clockTime(String(f[0]), on: midnight),
                          let pid = pid_t(f[1]),
                          let cycles = Int64(f[3]),
                          let ms = Int(f[4]) else { continue }
                    // Some bundles carry a LEFT-TO-RIGHT MARK in their display
                    // name -- WhatsApp does -- and the daemon passes the name
                    // through as it finds it. Invisible on its own, but it
                    // reorders the " · " separators around it once several
                    // names share a line. The foreground column strips the same
                    // character for the same reason.
                    let name = String(f[2]).replacingOccurrences(of: "\u{200E}", with: "")
                    guard !name.isEmpty, name != "-" else { continue }
                    rows.append(CPURow(time: t, pid: pid, process: name,
                                       cycles: cycles, cpuMs: ms,
                                       wakeups: Int(f[5]) ?? 0))
                }
            }
            rows.sort { $0.time < $1.time }
            let out = CPUDayData(recorded: exists, rows: rows)

            lock.lock()
            cached = out
            loadedDay = key
            loadedStamp = stamp
            lock.unlock()
            return out
        }
    }

    // MARK: - power

    /// One `power/<date>.tsv` row: what the CHIP was drawing, in milliwatts,
    /// averaged over a one-second burst.
    ///
    /// Machine-wide and never per process. `packageMw` is the platform's own
    /// combined figure and is NOT the sum of the three before it; a field the
    /// platform did not report is nil rather than zero, because zero here would
    /// be a claim that the part drew no power.
    struct PowerRow {
        let time: Date
        /// The window the average covers -- about a second -- NOT the gap since
        /// the last row. A consumer averages several; multiplying one by 3600
        /// invents an hour of load out of one second of it.
        let secs: Double
        let cpuMw: Int?
        let gpuMw: Int?
        let aneMw: Int?
        let packageMw: Int?
    }

    struct PowerDayData {
        /// The file exists. False means nobody was measuring -- which is the
        /// normal case, since the stream needs the root helper and the helper
        /// is opt-in.
        let recorded: Bool
        let rows: [PowerRow]
    }

    /// `power/<date>.tsv`, one day at a time, same shape and same reasons as
    /// `CPUDays`: the tab draws one day, and today's file grows while the panel
    /// is open. A day is ~1,440 rows at most.
    final class PowerDays {
        static let shared = PowerDays()

        private var loadedDay: String?
        private var loadedStamp: Date?
        private var cached = PowerDayData(recorded: false, rows: [])
        private let lock = NSLock()

        private init() {}

        func day(_ key: String) -> PowerDayData {
            let url = VitalsStore.powerDir.appendingPathComponent("\(key).tsv")
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            lock.lock()
            if loadedDay == key, stamp == loadedStamp { defer { lock.unlock() }; return cached }
            lock.unlock()

            var rows: [PowerRow] = []
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists, let midnight = VitalsStore.midnightFor(day: key),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    // Exactly six, for the same reason every other parse here
                    // insists on its count: the daemon appends from another
                    // process and a line caught mid-write must not be data.
                    guard f.count == 6,
                          let t = VitalsStore.clockTime(String(f[0]), on: midnight) else { continue }
                    func mw(_ i: Int) -> Int? { Int(f[i]) }      // "-" -> nil
                    rows.append(PowerRow(time: t, secs: Double(f[1]) ?? 1,
                                         cpuMw: mw(2), gpuMw: mw(3),
                                         aneMw: mw(4), packageMw: mw(5)))
                }
            }
            rows.sort { $0.time < $1.time }
            let out = PowerDayData(recorded: exists, rows: rows)

            lock.lock()
            cached = out
            loadedDay = key
            loadedStamp = stamp
            lock.unlock()
            return out
        }
    }


    // MARK: - draw

    /// One `draw/<date>.tsv` row: what the WHOLE MACHINE was drawing, and the
    /// current the screen's backlight was taking, both read straight off the
    /// hardware.
    ///
    /// The distinction from `power` is the entire point of the stream. `power`
    /// measures the chip; on this machine the chip is a small minority of the
    /// draw, so every hour the Battery tab shows was until now a measured sliver
    /// and one large inferred remainder. `systemMw` is that remainder's other
    /// end, measured.
    ///
    /// UNLIKE `PowerRow`, these are INSTANTANEOUS readings and there is no
    /// `secs` to say otherwise. Average several over an hour; never multiply one
    /// out across the minute it was taken in.
    struct DrawRow {
        let time: Date
        /// Whole-machine load. nil where the platform would not answer -- never
        /// zero, which would be a claim the machine drew nothing.
        let systemMw: Int?
        /// Signed: negative discharging, positive charging.
        let battMw: Int?
        /// The internal panel's LIGHT OUTPUT, 0-1000 per mille of full. nil
        /// while the panel sleeps or when there is no built-in display, which
        /// is NOT the same as a dark screen emitting nothing -- see the
        /// daemon's DrawStream for why it refuses to write 0.
        ///
        /// A brightness, not a current, and the daemon's own comment has the
        /// measurement behind that: every electrical figure the backlight
        /// driver publishes is frozen on this hardware.
        let screenPerMille: Int?
    }

    struct DrawDayData {
        /// The file exists. False for every day before the stream was added, so
        /// this is the flag the tab gates the measured rows on -- a day without
        /// it must keep saying what it always said rather than quietly showing
        /// blanks where numbers used to be.
        let recorded: Bool
        let rows: [DrawRow]
    }

    /// `draw/<date>.tsv`, one day at a time. Same cache and same reasons as
    /// `PowerDays`; ~1,440 rows a day at most.
    final class DrawDays {
        static let shared = DrawDays()

        private var loadedDay: String?
        private var loadedStamp: Date?
        private var cached = DrawDayData(recorded: false, rows: [])
        private let lock = NSLock()

        private init() {}

        func day(_ key: String) -> DrawDayData {
            let url = VitalsStore.drawDir.appendingPathComponent("\(key).tsv")
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            lock.lock()
            if loadedDay == key, stamp == loadedStamp { defer { lock.unlock() }; return cached }
            lock.unlock()

            var rows: [DrawRow] = []
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists, let midnight = VitalsStore.midnightFor(day: key),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard f.count == 4,
                          let t = VitalsStore.clockTime(String(f[0]), on: midnight) else { continue }
                    func num(_ i: Int) -> Int? { Int(f[i]) }     // "-" -> nil
                    rows.append(DrawRow(time: t, systemMw: num(1), battMw: num(2),
                                        screenPerMille: num(3)))
                }
            }
            rows.sort { $0.time < $1.time }
            let out = DrawDayData(recorded: exists, rows: rows)

            lock.lock()
            cached = out
            loadedDay = key
            loadedStamp = stamp
            lock.unlock()
            return out
        }
    }


    // MARK: - device

    /// One `device/<date>.tsv` row: a piece of hardware was ON for `secs` of the
    /// window ending at `time`.
    ///
    /// A row only exists for a device that was actually on, so an absent hour is
    /// an hour with nothing running -- not an hour nobody watched. That is the
    /// opposite of `cpu`, and the `recorded` flag beside it is what tells the
    /// two apart.
    ///
    /// `secs` is REAL on-time inside the window, not the window's length: a
    /// camera that ran five seconds writes 5.0. Summing it is therefore correct;
    /// counting rows is not.
    struct DeviceRow {
        let time: Date
        let secs: Double
        /// `camera` | `audio_in` | `audio_out`.
        let kind: String
        let name: String
    }

    struct DeviceDayData {
        let recorded: Bool
        let rows: [DeviceRow]
    }

    /// `device/<date>.tsv`, one day at a time. Smaller than every other stream
    /// here -- most minutes of most days write nothing at all.
    final class DeviceDays {
        static let shared = DeviceDays()

        private var loadedDay: String?
        private var loadedStamp: Date?
        private var cached = DeviceDayData(recorded: false, rows: [])
        private let lock = NSLock()

        private init() {}

        func day(_ key: String) -> DeviceDayData {
            let url = VitalsStore.deviceDir.appendingPathComponent("\(key).tsv")
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            lock.lock()
            if loadedDay == key, stamp == loadedStamp { defer { lock.unlock() }; return cached }
            lock.unlock()

            var rows: [DeviceRow] = []
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists, let midnight = VitalsStore.midnightFor(day: key),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard f.count == 4, let secs = Double(f[1]),
                          let t = VitalsStore.clockTime(String(f[0]), on: midnight) else { continue }
                    rows.append(DeviceRow(time: t, secs: secs,
                                          kind: String(f[2]), name: String(f[3])))
                }
            }
            rows.sort { $0.time < $1.time }
            let out = DeviceDayData(recorded: exists, rows: rows)

            lock.lock()
            cached = out
            loadedDay = key
            loadedStamp = stamp
            lock.unlock()
            return out
        }
    }


    // MARK: - Names

    /// `names.tsv`, keyed by netblock. One whois names a whole prefix, so this
    /// is small and mostly static: ~90 seeded entries plus whatever the daemon
    /// has learned.
    ///
    /// Reloaded only when the file's mtime moves. The panel asks for a name once
    /// per row per redraw and this must not become a file read each time.
    final class Names {
        static let shared = Names()

        private var entries: [(prefix: IPPrefix, name: String)] = []
        private var loadedStamp: Date?
        private let lock = NSLock()

        private init() {}

        /// Longest-prefix match, so a specific netblock beats the /10 it sits in.
        /// Returns nil rather than an address: when naming fails it falls
        /// back to words, and an address must never reach the table.
        func name(for address: String) -> String? {
            reloadIfNeeded()
            guard let bytes = IPPrefix.parseAddress(address) else { return nil }
            lock.lock(); defer { lock.unlock() }
            var best: (Int, String)? = nil
            for e in entries where e.prefix.contains(bytes) {
                if best == nil || e.prefix.bits > best!.0 { best = (e.prefix.bits, e.name) }
            }
            return best?.1
        }

        private func reloadIfNeeded() {
            let path = VitalsStore.namesFile.path
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            lock.lock()
            let needs = stamp != loadedStamp
            lock.unlock()
            guard needs else { return }

            var parsed: [(IPPrefix, String)] = []
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard f.count >= 2, let p = IPPrefix(String(f[0])) else { continue }
                    let name = String(f[1])
                    if !name.isEmpty { parsed.append((p, name)) }
                }
            }
            lock.lock()
            entries = parsed
            loadedStamp = stamp
            lock.unlock()
        }
    }

    // MARK: - Paths

    /// `proc/<date>.tsv` — the pid → executable path identity table, written by
    /// vitals-helper and shared by the net and cpu streams.
    ///
    /// WHY IT EXISTS AT ALL. A net row names a process the way a person reads
    /// it ("Google Chrome", "claude"), which is the right thing to show and the
    /// wrong thing to hand to an API — nothing can be read off a display name.
    /// The path can be, and it outlives the process, which is the whole point:
    /// a signature can only be taken from a RUNNING process, so before this
    /// file existed anything that ran for two seconds this morning could never
    /// be classified. See CodeSignature.swift.
    ///
    /// THE JOIN IS BY TIME, NOT BY PID. Pids recycle, within a day as well as
    /// across days, so the entry taken is the one with the greatest `started`
    /// **at or before** the moment the row was written. A pid with no entry that
    /// old has no path here, and the answer is nil — never the nearest entry.
    /// Naming the wrong binary is worse than naming none.
    ///
    /// `started` is when the PROCESS started, not when the sampler noticed it,
    /// and it is a full local ISO stamp -- so it is routinely EARLIER than the
    /// file it appears in (a program running for a week carries the same stamp
    /// in seven day files). An entry from an earlier day is clamped to that
    /// day's midnight, which preserves the ordering; one stamped later than the
    /// file's own day cannot apply to any row in it and is dropped.
    ///
    /// One day at a time, because the Net tab draws one day at a time, and
    /// reloaded only when the file's mtime moves — today's is appended to while
    /// the panel is open.
    final class NetPaths {
        static let shared = NetPaths()

        /// pid -> its sightings today, oldest first.
        private var byPid: [pid_t: [(at: Date, path: String)]] = [:]
        private var loadedDay: String?
        private var loadedStamp: Date?
        private let lock = NSLock()

        private init() {}

        /// The executable recorded for `pid` as of `time`, or nil if the
        /// daemon never wrote one that applies.
        func path(pid: pid_t, at time: Date) -> String? {
            let day = VitalsStore.dayKey(time)
            reloadIfNeeded(day: day)
            lock.lock(); defer { lock.unlock() }
            guard loadedDay == day, let sightings = byPid[pid] else { return nil }
            // Sorted ascending, so the last one at or before `time` wins.
            var best: String?
            for s in sightings {
                if s.at <= time { best = s.path } else { break }
            }
            return best
        }

        private func reloadIfNeeded(day: String) {
            let url = VitalsStore.procDir.appendingPathComponent("\(day).tsv")
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            lock.lock()
            let needs = (loadedDay != day) || (stamp != loadedStamp)
            lock.unlock()
            guard needs else { return }

            var parsed: [pid_t: [(at: Date, path: String)]] = [:]
            if let midnight = VitalsStore.midnightFor(day: day),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    // Exactly three, for the same reason parseNet insists on
                    // exactly ten: the daemon appends from another process and
                    // a line caught mid-write must not be read as data.
                    guard f.count == 3,
                          let at = VitalsStore.startedTime(String(f[0]),
                                                           dayStart: midnight),
                          let pid = pid_t(f[1]) else { continue }
                    let path = String(f[2])
                    guard path.hasPrefix("/") else { continue }   // header, or nonsense
                    parsed[pid, default: []].append((at, path))
                }
            }
            for k in parsed.keys { parsed[k]?.sort { $0.at < $1.at } }

            lock.lock()
            byPid = parsed
            loadedDay = day
            loadedStamp = stamp
            lock.unlock()
        }
    }

    // MARK: - Dates

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    fileprivate static func dayKeys(from: Date, to: Date) -> [String] {
        let a = dayKey(from), b = dayKey(to)
        return a == b ? [a] : [a, b]
    }

    fileprivate static func midnightFor(day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    /// `proc`'s `started` column: a full local ISO stamp, `yyyy-MM-ddTHH:mm:ss`.
    ///
    /// Clamped into the day being read, because that is what makes it comparable
    /// with the clock times every other stream carries. Earlier than the file's
    /// day -> that day's midnight, so it still sorts before every row in it.
    /// Later than the file's day -> nil, because it cannot apply to any row
    /// here. Anything that is not an ISO stamp is nil rather than guessed at.
    fileprivate static func startedTime(_ iso: String, dayStart: Date) -> Date? {
        let parts = iso.split(separator: "T", maxSplits: 1)
        guard parts.count == 2, let day = dayFormatter.date(from: String(parts[0]))
        else { return nil }
        if day < dayStart { return dayStart }
        if day > dayStart { return nil }
        return clockTime(String(parts[1]), on: dayStart)
    }

    /// `HH:MM:SS` against a known midnight. The day files store a clock time,
    /// not a full timestamp, so the day has to come from the filename.
    fileprivate static func clockTime(_ hhmmss: String, on midnight: Date) -> Date? {
        let p = hhmmss.split(separator: ":")
        guard p.count == 3,
              let h = Int(p[0]), let m = Int(p[1]), let s = Double(p[2]) else { return nil }
        return midnight.addingTimeInterval(Double(h) * 3600 + Double(m) * 60 + s)
    }
}

// MARK: - Incremental reading

/// A stateful view of the net store, for a panel that is currently open.
///
/// The day files are append-only, so re-parsing them from the top on every
/// redraw is work already done: drawing fifteen minutes cost a full pass over
/// the day, up to once a second, and late in the day that is 1.4MB and ~24k
/// rows to produce a table that changed by a handful of them. This keeps the
/// rows it has parsed and the byte offset it reached in each file, so a refresh
/// costs only what the daemon appended since -- typically a few hundred bytes.
///
/// Owned by NetStore and thrown away on close. Nothing here outlives the
/// dropdown, which is the rule the whole app is built around.
final class NetReader {

    private var rows: [VitalsStore.NetRow] = []

    /// Bytes consumed per day file, always at a line boundary.
    ///
    /// A partial trailing line is deliberately NOT consumed. The daemon appends
    /// from another process, so the tail can be half-written; taking it would
    /// manufacture exactly the torn rows the parser already rejects -- except
    /// here the missing half would never arrive, because the offset had moved
    /// past it. Leaving it costs one redraw's latency and nothing else.
    private var offsets: [String: Int] = [:]

    /// The oldest instant `rows` is known to cover. A window reaching further
    /// back than this cannot be served from what is retained.
    private var coveredFrom: Date?

    /// Rows within `window` of now, oldest first -- same contract as
    /// `VitalsStore.readNet`, which this replaces on the live path.
    func rows(window: TimeInterval, now: Date = Date()) -> [VitalsStore.NetRow] {
        let cutoff = now.addingTimeInterval(-window)

        // A widened window (15m -> 6h) asks for history that was dropped to
        // bound memory. Start over rather than serve a short answer.
        if let c = coveredFrom, cutoff < c { reset() }

        let days = VitalsStore.dayKeys(from: cutoff, to: now)
        var intact = true
        for day in days {
            if !advance(day: day, cutoff: cutoff, now: now) { intact = false }
        }
        // A file that shrank or vanished under us is not worth reconciling row
        // by row; the cold path is cheap enough to fall back to.
        if !intact {
            reset()
            for day in days { _ = advance(day: day, cutoff: cutoff, now: now) }
        }
        offsets = offsets.filter { days.contains($0.key) }

        // Rows that have fallen out of the window. `rows` is sorted, so these
        // are a prefix -- and dropping them is what bounds memory to the window
        // rather than to the day.
        if let i = rows.firstIndex(where: { $0.time >= cutoff }) {
            if i > 0 { rows.removeFirst(i) }
        } else {
            rows.removeAll()
        }

        coveredFrom = cutoff
        return rows
    }

    func reset() {
        rows.removeAll()
        offsets.removeAll()
        coveredFrom = nil
    }

    /// Parse whatever has been appended to one day file since the last look.
    /// Returns false when the file no longer matches what was read from it.
    private func advance(day: String, cutoff: Date, now: Date) -> Bool {
        let url = VitalsStore.netDir.appendingPathComponent("\(day).tsv")
        let consumed = offsets[day] ?? 0
        guard let h = try? FileHandle(forReadingFrom: url) else {
            // No file at all is normal: a day with no traffic yet, or the first
            // moments after midnight. A file we had already read from and can
            // no longer open is not.
            return consumed == 0
        }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return false }

        let size = Int(end)
        if size < consumed { return false }     // truncated, rotated or replaced
        if size == consumed { return true }     // nothing new since last time

        guard (try? h.seek(toOffset: UInt64(consumed))) != nil,
              let chunk = try? h.readToEnd(), !chunk.isEmpty else { return false }
        guard let nl = chunk.lastIndex(of: 0x0A) else { return true }  // no whole line yet

        let whole = chunk[chunk.startIndex...nl]
        offsets[day] = consumed + whole.count

        let fresh = VitalsStore.parseNet(Data(whole), day: day, cutoff: cutoff, now: now)
        guard !fresh.isEmpty else { return true }

        // Each file is written in time order and days are visited in order, so
        // appending keeps `rows` sorted. The exception is a late append to
        // yesterday's file after today's has been read; sort only then.
        if let last = rows.last, let first = fresh.first, first.time < last.time {
            rows = (rows + fresh).sorted { $0.time < $1.time }
        } else {
            rows += fresh
        }
        return true
    }
}

// MARK: - Prefix matching

/// Just enough CIDR to join a row's address to a name. The daemon owns the hard
/// part -- whois, Cymru, the ladder, the cache. This only has to read the answer.
struct IPPrefix {
    let bytes: [UInt8]
    let bits: Int

    init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard parts.count == 2,
              let addr = IPPrefix.parseAddress(String(parts[0])),
              let b = Int(parts[1]), b >= 0, b <= addr.count * 8 else { return nil }
        bytes = addr
        bits = b
    }

    func contains(_ addr: [UInt8]) -> Bool {
        guard addr.count == bytes.count else { return false }      // never match v4 against v6
        var remaining = bits
        var i = 0
        while remaining >= 8 {
            if addr[i] != bytes[i] { return false }
            remaining -= 8; i += 1
        }
        if remaining > 0 {
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remaining))
            if (addr[i] & mask) != (bytes[i] & mask) { return false }
        }
        return true
    }

    /// IPv4 dotted quad, or IPv6 via `inet_pton`. Returns 4 or 16 bytes.
    static func parseAddress(_ s: String) -> [UInt8]? {
        if s.contains(":") {
            var buf = [UInt8](repeating: 0, count: 16)
            let ok = s.withCString { inet_pton(AF_INET6, $0, &buf) == 1 }
            return ok ? buf : nil
        }
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out = [UInt8]()
        for p in parts {
            guard let v = UInt16(p), v <= 255 else { return nil }
            out.append(UInt8(v))
        }
        return out
    }
}

// MARK: - Being told, rather than polling

/// Darwin notification subscriber.
///
/// The daemon appends to the day file and then posts a key. Two properties of
/// that mechanism decide how this is written: the notification **coalesces** and
/// is **not queued**, so a consumer that was asleep gets one wakeup rather than
/// one per missed record. It therefore means "there is new data", never "here is
/// the datum" -- always re-read, never try to derive content from the signal.
final class VitalsNotify {
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var registered = false

    static let netKey = "local.ktutnik.vitals.net"
    static let batteryKey = "local.ktutnik.vitals.battery"

    func subscribe(key: String, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        unsubscribe()
        let status = notify_register_dispatch(key, &token, queue) { _ in handler() }
        registered = (status == NOTIFY_STATUS_OK)
        if !registered {
            NSLog("VitalsNotify: could not register for \(key) (status \(status))")
        }
    }

    func unsubscribe() {
        if registered { notify_cancel(token) }
        registered = false
        token = NOTIFY_TOKEN_INVALID
    }

    deinit { unsubscribe() }
}
