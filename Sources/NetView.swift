import SwiftUI

// =====================================================================
// MARK: - The data the Net tab draws
// =====================================================================
//
// Everything below the `NetSnapshotProvider` seam is mock (a real
// 60-second capture, transcribed). Everything above it is the finished view.
// Phase 3 replaces `MockNetProvider` with one backed by `NetStore` and the view
// does not change -- that is the whole point of the seam.

/// Which of the three states the pane is in.
///
/// These are not decoration. Nothing runs while the dropdown is closed, so
/// every single open starts at `.pending` with an empty sparkline and climbs from
/// there. A user who opens the tab for five seconds to glance at it will see
/// `.pending` far more often than they ever see a full table.
enum NetPhase {
    /// Sources enumerated, but the baseline query has been discarded
    /// and no delta exists yet. We know *who* has sockets open, not how much moved.
    case pending
    /// Deltas are arriving and nothing has moved. Distinct from `.pending`: this is
    /// a real answer ("your Mac is quiet"), not a missing one.
    case empty
    /// Deltas are arriving and something moved.
    case live
    /// The vitals daemon is not recording. Carries the words to say.
    ///
    /// This is not a variant of `.empty`. A quiet machine and a dead recorder
    /// render identically unless something insists they do not, and that failure
    /// is silent by nature -- hence a separate case the view cannot forget to
    /// handle, rather than an empty table and a hope.
    case unavailable(String)
}

extension NetPhase: Equatable {
    static func == (a: NetPhase, b: NetPhase) -> Bool {
        switch (a, b) {
        case (.pending, .pending), (.empty, .empty), (.live, .live): return true
        case let (.unavailable(x), .unavailable(y)): return x == y
        default: return false
        }
    }
}

/// One poll interval's worth of bytes. The sparkline is a list of these.
struct NetTick: Identifiable {
    let id: Int
    let down: Int64
    let up: Int64
}

/// A row of "Who was talking".
struct NetTalker: Identifiable {
    let id: String
    /// What to print. Never blank -- a pid that died before it could be named
    /// still gets words ("pid 41207"), never an empty cell.
    let name: String
    /// Tooltip only: pid, path, socket count.
    let detail: String
    let down: Int64
    let up: Int64
    /// The process was gone before its name could be read.
    let exited: Bool

    var total: Int64 { down + up }
}

/// How confident the "Went to" column is about a name. Never an address in any
/// of these states -- when naming fails it falls back to words.
enum NetNameState {
    case named          // whois / route owner / registrable domain
    case resolving      // lookup in flight; the row is drawn, the name is not known yet
    case local          // This Mac, a device on your network, a Tailscale peer
    case unknown        // the ladder hit its floor
}

/// A row of "Went to".
struct NetDestination: Identifiable {
    let id: String
    let name: String
    /// Tooltip only. This is the one place an IP address is allowed to appear.
    let detail: String
    let down: Int64
    let up: Int64
    let state: NetNameState
    /// How many distinct remote hosts folded into this one name.
    let hosts: Int

    var total: Int64 { down + up }
}

/// A row of the table: one app, one destination, what moved between them.
///
/// This is the shape the tab actually draws. The by-process and by-destination
/// rollups still exist in the store and still feed the header counts, but they
/// are aggregations of this -- and unlike them, these rows cover every byte,
/// because traffic with no peer is a row here ("No destination") rather than a
/// gap that has to be explained in a footnote.
struct NetFlow: Identifiable {
    let id: String
    /// Never blank: a pid that died before it could be named still gets words.
    let app: String
    /// Tooltip only: pid, path, socket count.
    let appDetail: String
    /// Never an address -- when naming fails it falls back to words.
    let destination: String
    /// Tooltip only. This is the one place an address may appear.
    let destinationDetail: String
    let down: Int64
    let up: Int64
    let state: NetNameState
    /// The process is gone.
    let exited: Bool
    /// One pid behind this row. Kept so a signature can be read off the live
    /// process; on its own it proves nothing, which is what `lastSeen` is for.
    var pid: pid_t = 0
    /// The last time this pid was seen moving bytes. A pid that started AFTER
    /// this instant is a different process wearing a recycled number, and the
    /// resolver rejects it on exactly that test.
    var lastSeen: Date = .distantPast

    var total: Int64 { down + up }
}

/// One app and everything it talked to -- a folder and its contents.
struct NetAppGroup: Identifiable {
    let id: String
    let app: String
    let appDetail: String
    /// Every process behind this name has exited.
    let exited: Bool
    let down: Int64
    let up: Int64
    /// Destinations, busiest first.
    let children: [NetFlow]

    var total: Int64 { down + up }
}

/// Fold the flat pair rows into the tree the tab draws.
///
/// Grouped by app NAME, not by pid: two Chrome helpers are one "Google Chrome"
/// folder, which is what a person reading this wants. The pids stay visible in
/// each child's tooltip.
func netGroups(from flows: [NetFlow]) -> [NetAppGroup] {
    var byApp: [String: [NetFlow]] = [:]
    for f in flows { byApp[f.app, default: []].append(f) }

    return byApp.map { app, rows in
        let kids = rows.sorted {
            $0.total == $1.total ? $0.destination < $1.destination : $0.total > $1.total
        }
        return NetAppGroup(id: app,
                           app: app,
                           appDetail: kids.first?.appDetail ?? app,
                           exited: kids.allSatisfy(\.exited),
                           down: kids.reduce(0) { $0 + $1.down },
                           up: kids.reduce(0) { $0 + $1.up },
                           children: kids)
    }
    // Apps read alphabetically, so a given app sits in the same place every time
    // you open the tab instead of jumping around as traffic shifts. Destinations
    // inside a folder stay busiest-first -- that is a question about bytes, not
    // about names. One consequence worth keeping in mind: the row order no longer
    // tells you who is loudest, so the CHART column is now the only thing that
    // does, and it earns its width.
    .sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
}

/// Everything the view needs for one frame.
struct NetSnapshot {
    var phase: NetPhase
    /// Seconds since the dropdown opened. There is no history before that.
    var elapsed: TimeInterval
    /// Poll interval, for labelling the sparkline.
    var interval: TimeInterval
    var ticks: [NetTick]
    /// The table. One row per app/destination pair, busiest first.
    var flows: [NetFlow]
    /// Aggregations of `flows`, kept for the header counts.
    var talkers: [NetTalker]
    var destinations: [NetDestination]
    /// Distinct remote hosts seen, before they were rolled up into names.
    var hostCount: Int
    /// Bytes attributable to a process but to no destination -- broadcast and
    /// multicast have no peer. The two tables therefore do not
    /// add up, and the view says so rather than letting it read as a bug.
    var noPeerDown: Int64
    var noPeerUp: Int64
    /// The day this snapshot describes. The chart's axis is always this whole
    /// day, midnight to midnight, so it is needed for drawing and not merely
    /// for the title.
    var day: Date = Calendar.current.startOfDay(for: Date())
    /// Throughput over the last minute of TODAY, whichever day is on screen --
    /// the Net tab's equivalent of the Battery tab's live charge readout.
    var liveBytesPerSecond: Double = 0

    /// The tree. Derived, so `flows` stays the single source of truth and the
    /// mock and the live store cannot disagree about how grouping works.
    var groups: [NetAppGroup] { netGroups(from: flows) }

    /// Off `flows`, which the table is built from anyway. Summing a second
    /// rollup of the same rows was one extra full pass per rebuild to reach
    /// the same two numbers. `talkers` survives only for the mock.
    var totalDown: Int64 {
        talkers.isEmpty ? flows.reduce(0) { $0 + $1.down } : talkers.reduce(0) { $0 + $1.down }
    }
    var totalUp: Int64 {
        talkers.isEmpty ? flows.reduce(0) { $0 + $1.up } : talkers.reduce(0) { $0 + $1.up }
    }
    var bytesPerSecond: Double {
        elapsed > 0 ? Double(totalDown + totalUp) / elapsed : 0
    }
}

/// The seam. Phase 3 supplies a `NetStore`-backed implementation of this and
/// nothing in the view has to move.
protocol NetSnapshotProvider {
    var snapshot: NetSnapshot { get }
}

/// What the view observes. Phase 3 changed only what it is constructed with:
/// the live `NetStore` instead of the mock, plus a subscription so the store can
/// say when it changed rather than being polled a second time.
final class NetFeed: ObservableObject {
    @Published private(set) var snapshot: NetSnapshot
    private let provider: NetSnapshotProvider
    private var unsubscribe: (() -> Void)?

    init(provider: NetSnapshotProvider = NetFeed.defaultProvider()) {
        self.provider = provider
        self.snapshot = provider.snapshot
        // The mock is a constant and has nothing to say; the store does.
        unsubscribe = (provider as? NetSnapshotStream)?.observe { [weak self] in
            guard let self else { return }
            self.snapshot = self.provider.snapshot
        }
    }

    deinit { unsubscribe?() }

    /// The live store, unless `NETMOCK` asks for the transcribed reference
    /// capture (`NETMOCK=live|pending|empty`) so all three states can still be
    /// rendered offscreen without a network.
    static func defaultProvider() -> NetSnapshotProvider {
        if ProcessInfo.processInfo.environment["NETMOCK"] != nil {
            return MockNetProvider.fromEnvironment()
        }
        return NetStore.shared
    }

    /// Kept for a caller that would rather pull than be told.
    func refresh() { snapshot = provider.snapshot }
}

// =====================================================================
// MARK: - Mock provider (a real capture, ISP and LAN addresses anonymised)
// =====================================================================

/// A real capture, so the layout is exercised against realistic
/// names and magnitudes rather than lorem ipsum: **73.0 KB down, 103.1 KB up,
/// ~2.9 KB/s, 14 processes, 26 remote hosts** over one idle minute, with two
/// ten-second bursts carrying two thirds of it.
///
/// `NETMOCK=pending` / `NETMOCK=empty` in the environment picks the other two
/// states, so all three can be rendered offscreen without touching `main.swift`.
struct MockNetProvider: NetSnapshotProvider {
    let phase: NetPhase

    static func fromEnvironment() -> MockNetProvider {
        switch ProcessInfo.processInfo.environment["NETMOCK"]?.lowercased() {
        case "pending": return MockNetProvider(phase: .pending)
        case "empty":   return MockNetProvider(phase: .empty)
        case "down":    return MockNetProvider(phase: .unavailable(
                            "vitals is not running.\nNothing is recording, so there is nothing to show."))
        default:        return MockNetProvider(phase: .live)
        }
    }

    var snapshot: NetSnapshot {
        switch phase {
        case .unavailable:
            // NETMOCK=down, so the dead-producer state can be rendered offscreen
            // like any other. It is the one state that cannot be reached by
            // waiting, which is exactly why it needs to be reachable here.
            return NetSnapshot(phase: phase, elapsed: 0, interval: 0, ticks: [],
                               flows: [], talkers: [], destinations: [],
                               hostCount: 0, noPeerDown: 0, noPeerUp: 0)
        case .pending:
            // 2.4s in: sockets enumerated, baseline discarded, no delta yet.
            return NetSnapshot(phase: .pending, elapsed: 2.4, interval: 2,
                               ticks: [],
                               flows: [],
                               talkers: Self.talkers.map {
                                   NetTalker(id: $0.id, name: $0.name, detail: $0.detail,
                                             down: 0, up: 0, exited: false)
                               },
                               destinations: [], hostCount: 0,
                               noPeerDown: 0, noPeerUp: 0)
        case .empty:
            return NetSnapshot(phase: .empty, elapsed: 18, interval: 2,
                               ticks: (0..<9).map { NetTick(id: $0, down: 0, up: 0) },
                               flows: [],
                               talkers: [], destinations: [], hostCount: 0,
                               noPeerDown: 0, noPeerUp: 0)
        case .live:
            return NetSnapshot(phase: .live, elapsed: 60, interval: 2,
                               ticks: Self.ticks,
                               flows: Self.flows,
                               talkers: Self.talkers,
                               destinations: Self.destinations,
                               hostCount: 26,
                               noPeerDown: 1_300, noPeerUp: 2_900)
        }
    }

    // --- rows -------------------------------------------------------------
    // Figures in whole bytes; decimal KB (1000) throughout, so the numbers on
    // screen read exactly as the capture recorded them.

    private static func kb(_ v: Double) -> Int64 { Int64((v * 1000).rounded()) }

    private static func flow(_ id: String, _ app: String, _ dest: String,
                             _ down: Double, _ up: Double,
                             _ state: NetNameState = .named,
                             exited: Bool = false, detail: String = "") -> NetFlow {
        NetFlow(id: id, app: app, appDetail: "\(app) \u{00b7} mock row",
                destination: dest,
                destinationDetail: detail.isEmpty ? "from the reference capture" : detail,
                down: kb(down), up: kb(up), state: state, exited: exited)
    }

    /// The app-to-destination join from that capture (ISP and LAN addresses
    /// swapped for documentation ranges, everything else verbatim), so the
    /// table is exercised against real pairs -- including the two rows that only
    /// exist in this shape: a peerless multicast row, and the loopback pair where
    /// Tailscale's two halves talk to each other.
    static let flows: [NetFlow] = [
        flow("f1",  "Microsoft Updat\u{2026}", "Your ISP", 10.6, 5.5,
             exited: true, detail: "203.0.113.0/24 \u{00b7} whois"),
        flow("f2",  "Microsoft Updat\u{2026}", "Your ISP", 10.6, 5.5,
             exited: true, detail: "198.51.100.0/24 \u{00b7} whois"),
        flow("f3",  "Microsoft Updat\u{2026}", "Microsoft Corporation", 10.5, 4.9,
             exited: true, detail: "20.64.0.0/10 \u{00b7} whois"),
        flow("f4",  "Microsoft Updat\u{2026}", "Microsoft Corporation", 9.8, 8.6,
             exited: true, detail: "20.64.0.0/10 \u{00b7} whois"),
        flow("f5",  "claude", "Anthropic, PBC", 1.1, 22.0,
             detail: "160.79.104.0/23 \u{00b7} whois"),
        flow("f6",  "claude", "Google Cloud Platform", 0.349, 20.1,
             detail: "34.148.0.0/14 \u{00b7} cymru"),
        flow("f7",  "Google Chrome", "Google LLC", 7.4, 4.9,
             detail: "8.8.4.0/24 \u{00b7} whois \u{00b7} DNS-over-HTTPS"),
        flow("f8",  "Google Chrome", "Google LLC", 5.8, 5.5,
             detail: "172.217.116.0/24 \u{00b7} whois"),
        flow("f9",  "azmcp", "Microsoft Corporation", 1.1, 8.0,
             detail: "20.64.0.0/10 \u{00b7} whois"),
        flow("f10", "Tailscale", "This Mac", 7.3, 0, .local,
             detail: "127.0.0.1 \u{00b7} loopback"),
        flow("f11", "Tailscale", "This Mac", 0, 7.3, .local,
             detail: "127.0.0.1 \u{00b7} loopback"),
        flow("f12", "Google Chrome", "Facebook", 2.6, 3.2,
             detail: "57.144.0.0/14 \u{00b7} whois"),
        flow("f13", "usbmuxd", "Device on your network", 2.3, 2.2, .local,
             detail: "192.168.1.10 \u{00b7} your LAN"),
        flow("f14", "mDNSResponder", "No destination", 1.3, 2.9, .local,
             detail: "broadcast, multicast or a socket that never connected"),
        flow("f15", "Google Chrome", "CloudFront", 1.7, 1.5,
             detail: "13.227.180.0/24 \u{00b7} whois"),
        flow("f16", "claude", "Resolving\u{2026}", 0.19, 0, .resolving,
             detail: "104.192.137.14"),
    ]

    static let talkers: [NetTalker] = [
        // The capture's busiest talker: a Microsoft updater that had already exited.
        NetTalker(id: "p1", name: "pid 41207", detail: "exited before it could be named · 6 sockets",
                  down: kb(33.8), up: kb(32.2), exited: true),
        NetTalker(id: "p2", name: "Claude Code", detail: "node · pid 38812 · 3 sockets",
                  down: kb(3.1), up: kb(40.6), exited: false),
        NetTalker(id: "p3", name: "Google Chrome", detail: "pid 1184 · 31 sockets",
                  down: kb(23.8), up: kb(9.8), exited: false),
        NetTalker(id: "p4", name: "apsd", detail: "Apple Push · pid 182 · 2 sockets",
                  down: kb(3.4), up: kb(5.8), exited: false),
        NetTalker(id: "p5", name: "Slack", detail: "pid 2041 · 4 sockets",
                  down: kb(2.4), up: kb(4.3), exited: false),
        NetTalker(id: "p6", name: "Dropbox", detail: "pid 1622 · 5 sockets",
                  down: kb(1.2), up: kb(3.9), exited: false),
        NetTalker(id: "p7", name: "mDNSResponder", detail: "pid 231 · multicast only",
                  down: kb(1.1), up: kb(2.3), exited: false),
        NetTalker(id: "p8", name: "Mail", detail: "pid 3310 · 2 sockets",
                  down: kb(1.4), up: kb(1.5), exited: false),
        NetTalker(id: "p9", name: "trustd", detail: "certificate checks · pid 199",
                  down: kb(1.2), up: kb(0.6), exited: false),
        NetTalker(id: "p10", name: "nsurlsessiond", detail: "background downloads · pid 640",
                  down: kb(0.9), up: kb(0.6), exited: false),
        NetTalker(id: "p11", name: "Spotify", detail: "pid 2855 · 3 sockets",
                  down: kb(0.4), up: kb(0.7), exited: false),
        NetTalker(id: "p12", name: "rapportd", detail: "Continuity · pid 512 · multicast only",
                  down: kb(0.2), up: kb(0.4), exited: false),
        NetTalker(id: "p13", name: "identityservicesd", detail: "iMessage · pid 488",
                  down: kb(0.1), up: kb(0.2), exited: false),
        NetTalker(id: "p14", name: "netbiosd", detail: "pid 377 · broadcast only",
                  down: 0, up: kb(0.2), exited: false),
    ]

    static let destinations: [NetDestination] = [
        NetDestination(id: "d1", name: "Anthropic, PBC", detail: "160.79.104.0/23 · whois",
                       down: kb(3.1), up: kb(40.6), state: .named, hosts: 2),
        NetDestination(id: "d2", name: "Microsoft Corporation", detail: "20.64.0.0/10 · whois",
                       down: kb(30.2), up: kb(29.7), state: .named, hosts: 4),
        NetDestination(id: "d3", name: "Google LLC", detail: "8.8.4.0/24, 142.250.0.0/15 · whois",
                       down: kb(12.4), up: kb(4.1), state: .named, hosts: 3),
        NetDestination(id: "d4", name: "Google Cloud Platform", detail: "34.148.0.0/14 · route owner",
                       down: kb(7.2), up: kb(2.6), state: .named, hosts: 2),
        NetDestination(id: "d5", name: "Akamai Technologies", detail: "23.32.0.0/11 · whois",
                       down: kb(4.6), up: kb(1.2), state: .named, hosts: 2),
        NetDestination(id: "d6", name: "Apple Inc.", detail: "17.0.0.0/8 · whois",
                       down: kb(3.4), up: kb(5.8), state: .named, hosts: 2),
        NetDestination(id: "d7", name: "Amazon Web Services", detail: "104.192.136.0/21 · whois · hosts Atlassian",
                       down: kb(2.8), up: kb(3.4), state: .named, hosts: 2),
        NetDestination(id: "d8", name: "Cloudflare, Inc.", detail: "104.16.0.0/13 · whois",
                       down: kb(2.1), up: kb(1.7), state: .named, hosts: 1),
        NetDestination(id: "d9", name: "Slack Technologies", detail: "99.86.0.0/16 · whois",
                       down: kb(1.4), up: kb(3.1), state: .named, hosts: 1),
        NetDestination(id: "d10", name: "Dropbox, Inc.", detail: "162.125.0.0/16 · whois",
                       down: kb(1.2), up: kb(3.9), state: .named, hosts: 1),
        NetDestination(id: "d11", name: "Fastly", detail: "151.101.0.0/16 · whois",
                       down: kb(0.9), up: kb(0.4), state: .named, hosts: 1),
        NetDestination(id: "d12", name: "Spotify AB", detail: "35.186.224.0/20 · route owner",
                       down: kb(0.7), up: kb(0.6), state: .named, hosts: 1),
        NetDestination(id: "d13", name: "facebook.com", detail: "reverse DNS · edge-star-mini-shv-01-sub1.facebook.com",
                       down: kb(0.5), up: kb(0.3), state: .named, hosts: 1),
        NetDestination(id: "d14", name: "Example ISP", detail: "203.0.113.0/24 · route owner",
                       down: kb(0.4), up: kb(0.9), state: .named, hosts: 1),
        NetDestination(id: "d15", name: "This Mac", detail: "127.0.0.1 · loopback",
                       down: kb(0.3), up: kb(0.3), state: .local, hosts: 1),
        NetDestination(id: "d16", name: "Device on your network", detail: "192.168.1.0/24 · no Bonjour name",
                       down: kb(0.2), up: kb(0.4), state: .local, hosts: 2),
        NetDestination(id: "d17", name: "Tailscale peer", detail: "100.64.0.0/10 · CGNAT range",
                       down: kb(0.1), up: kb(0.6), state: .local, hosts: 1),
        NetDestination(id: "d18", name: "Resolving…", detail: "whois lookup in flight",
                       down: kb(0.1), up: kb(0.4), state: .resolving, hosts: 2),
        NetDestination(id: "d19", name: "Unknown host", detail: "no whois, no route owner, no reverse DNS",
                       down: kb(0.1), up: kb(0.2), state: .unknown, hosts: 1),
    ]

    /// 30 two-second samples. Traffic arrives in bursts -- the capture measured two
    /// ten-second windows carrying two thirds of the minute, so the shape here
    /// has two, not a flat hum.
    static let ticks: [NetTick] = {
        let dw: [Double] = [2, 1, 3, 2, 1, 4,
                            22, 38, 31, 26, 18,
                            6, 3, 2, 1, 2, 3, 2,
                            9, 27, 34, 29, 21, 12,
                            4, 2, 3, 1, 2, 1]
        let uw: [Double] = [3, 2, 2, 4, 3, 5,
                            14, 19, 17, 15, 12,
                            8, 6, 5, 4, 6, 7, 5,
                            21, 36, 41, 33, 26, 18,
                            9, 6, 4, 3, 2, 2]
        let down = distribute(kb(73.0), over: dw)
        let up = distribute(kb(103.1), over: uw)
        return (0..<dw.count).map { NetTick(id: $0, down: down[$0], up: up[$0]) }
    }()

    /// Split `total` across `weights` so the parts add back up exactly -- the
    /// sparkline must not contradict the header by a rounding byte.
    private static func distribute(_ total: Int64, over weights: [Double]) -> [Int64] {
        let sum = weights.reduce(0, +)
        var out = weights.map { Int64((Double(total) * $0 / sum).rounded(.down)) }
        var short = total - out.reduce(0, +)
        var i = 0
        while short > 0 { out[i % out.count] += 1; short -= 1; i += 1 }
        return out
    }
}

// =====================================================================
// MARK: - Formatting
// =====================================================================

enum NetFormat {
    /// Decimal KB, matching how the reference capture was recorded. One decimal below
    /// 100 units so a 1.2 KB row is not flattened to "1 KB".
    static func bytes(_ v: Int64) -> String {
        let d = Double(v)
        switch d {
        case ..<1_000:      return "\(v) B"
        case ..<1_000_000:  return unit(d / 1_000, "KB")
        case ..<1_000_000_000: return unit(d / 1_000_000, "MB")
        default:            return unit(d / 1_000_000_000, "GB")
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond.rounded())) + "/s"
    }

    /// Always one decimal. Dropping it above 100 turned the capture's 103.1 KB into a
    /// flat "103 KB", and the header then disagreed with the rows under it.
    private static func unit(_ v: Double, _ suffix: String) -> String {
        String(format: "%.1f %@", v, suffix)
    }

    /// "4s", "1m 04s", "12m 30s".
    static func elapsed(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "\(t)s" : String(format: "%dm %02ds", t / 60, t % 60)
    }
}

// =====================================================================
// MARK: - Palette
// =====================================================================

/// Two series, one unit (bytes), one scale -- so one axis, two hues.
///
/// Down/up are deliberately NOT the Battery tab's red/green: there, red means
/// "you lost charge" and green means "you gained it", and a download is neither
/// good nor bad. Blue/orange carries identity without smuggling in a verdict,
/// and it is the pair that survives colour-blind simulation. Each step was
/// validated against its own surface rather than flipped from the other mode:
/// lightness band, chroma floor, protan/deutan/tritan separation and contrast
/// all pass in both. Every figure is also printed as text beside its mark, so
/// colour is never the only thing carrying the difference.
enum NetPalette {
    static func down(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.039, green: 0.518, blue: 1.000)   // #0A84FF
            : Color(red: 0.000, green: 0.412, blue: 0.851)   // #0069D9
    }
    /// The same step reads correctly on both surfaces, so it does not change.
    static func up(_ scheme: ColorScheme) -> Color {
        Color(red: 0.851, green: 0.467, blue: 0.024)         // #D97706
    }
}

// =====================================================================
// MARK: - The pane
// =====================================================================

struct NetView: View {
    @StateObject private var feed: NetFeed
    @ObservedObject private var store = NetStore.shared
    @ObservedObject private var signatures = SignatureIndex.shared
    @Environment(\.colorScheme) private var scheme

    @State private var showCalendar = false

    /// Which folders are open. Empty by default, so every app starts shut and the
    /// first thing on screen is the full list of apps rather than the first few
    /// expanded ones. Session state only.
    @State private var expanded: Set<String> = []

    /// Render-only: `--render … net expand` opens every folder, so the capture
    /// exercises child rows. Nesting is the one thing a collapsed capture
    /// cannot show, and it is exactly what broke when the signing badge moved
    /// in front of the name -- children ended up left of their own parent.
    ///
    /// Set through the VOLATILE argument domain, never written to disk: an
    /// offscreen capture must not leave the installed app with every folder
    /// hanging open forever.
    static let expandAllKey = "NetExpandAll"
    private let expandAll = UserDefaults.standard.bool(forKey: NetView.expandAllKey)

    init() { _feed = StateObject(wrappedValue: NetFeed()) }
    init(feed: NetFeed) { _feed = StateObject(wrappedValue: feed) }

    private var snap: NetSnapshot { feed.snapshot }

    private var isUnavailable: Bool {
        if case .unavailable = snap.phase { return true }
        return false
    }

    var body: some View {
        // Same shape as the Battery tab, in the same order: navigate, then the
        // day as a picture, then the day as a table, then the day as totals.
        // The calendar floats over the table rather than pushing it down -- an
        // NSPopover does not reliably resize to a changing SwiftUI frame.
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                // No chart and no legend when nothing is recording. A flat line
                // at zero is a claim about the machine, and we are not in a
                // position to make it.
                if !isUnavailable {
                    NetDayChartView(day: snap.day, ticks: snap.ticks, scheme: scheme)
                    legend
                }
                hairline

                if case .unavailable(let why) = snap.phase {
                    inlineNote(why, icon: "bolt.horizontal.circle")
                        .frame(maxHeight: .infinity)
                } else if snap.flows.isEmpty {
                    quietState
                } else {
                    flowSection
                }

                hairline
                footer
                signatureLegend
                footnote
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

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(store.day)
            ? "'Today' \u{00b7} EEE d MMM" : "EEE d MMM yyyy"
        return f.string(from: store.day)
    }

    /// Byte-for-byte the Battery tab's header: two chevrons, a calendar button
    /// carrying the day, a "Today" link that appears only when it would do
    /// something, and the live readout on the right.
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

            liveReadout
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

    /// What the network is doing NOW, not on the day being read -- the same
    /// choice the Battery tab makes by showing the live charge while you page
    /// through history. The second line says whether the daemon is recording,
    /// because an empty chart and a stopped producer must never look alike.
    private var liveReadout: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(isUnavailable ? "\u{2014}" : NetFormat.rate(snap.liveBytesPerSecond))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(isUnavailable ? "not recording" : "now")
                .font(.system(size: 9))
                .foregroundStyle(isUnavailable ? AnyShapeStyle(Color.orange)
                                               : AnyShapeStyle(.secondary))
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

    /// Two series always get a legend. The swatch carries the hue; the words stay
    /// in ordinary text ink so nothing depends on seeing the colour.
    private var legend: some View {
        // Up first, because up is now the upper half. A legend that lists the
        // series in the opposite order to the picture makes the reader do the
        // mapping twice.
        HStack(spacing: 12) {
            legendKey("Up", NetPalette.up(scheme))
            legendKey("Down", NetPalette.down(scheme))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func legendKey(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 9, height: 3)
            Text(text).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: sections

    /// The table. Sorted by total bytes, so the bar and the row order say the
    /// same thing: the bar is each row's share of the busiest row.
    private var flowSection: some View {
        VStack(spacing: 0) {
            // No section title. The Battery tab goes straight from its chart to
            // its column header, and "TRAFFIC" over the only table in the pane
            // was labelling the obvious; the counts it carried now sit in the
            // footer with the other whole-day figures.
            flowColumnHeader
            Group {
                if snap.flows.isEmpty {
                    inlineNote(snap.phase == .pending
                               ? "Rows appear with the first measured bytes.\nEvery name lookup runs in the background, so a row is never held back waiting for one."
                               : "Nothing has opened a socket yet.",
                               icon: "globe")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(snap.groups) { g in
                                appRow(g)
                                if expanded.contains(g.id) || expandAll {
                                    ForEach(g.children) { f in
                                        destinationRow(f)
                                    }
                                }
                            }
                        }
                    }
                    .onAppear { resolveSignatures() }
                    .onChange(of: snap.groups.map(\.id)) { _, _ in resolveSignatures() }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// An app folder. Its bar is the app's whole total, so the parent rows alone
    /// answer "who is loudest" even with every folder shut.
    private func appRow(_ g: NetAppGroup) -> some View {
        NetRowView(name: g.app,
                   detail: g.exited
                       ? "\(g.appDetail)\nNo process behind these rows is still running. The app may have been started again since; this is about the processes that moved these bytes."
                       : "\(g.appDetail)\nStill running.",
                   expanded: expanded.contains(g.id) || expandAll,
                   dimmed: g.exited,
                   tag: g.exited ? "exited" : nil,
                   signing: signatures.verdict(for: g.app),
                   pending: snap.phase == .pending,
                   down: g.down, up: g.up,
                   scale: flowScale,
                   scheme: scheme,
                   onToggle: { toggle(g.id) })
    }

    /// Ask for a signature for every app on screen that has not got one.
    ///
    /// Driven from the view rather than the store because the set that matters
    /// is the set being drawn -- a dozen or two apps, not the ~560 processes on
    /// the machine. Each candidate carries the last time its pid was seen
    /// moving bytes, which is what lets the resolver reject a recycled pid.
    private func resolveSignatures() {
        let wanted = snap.groups.map { g in
            (app: g.app,
             candidates: g.children.map { (pid: $0.pid, seen: $0.lastSeen) })
        }
        signatures.resolve(wanted)
    }

    private func destinationRow(_ f: NetFlow) -> some View {
        NetRowView(name: f.destination,
                   detail: f.destinationDetail,
                   child: true,
                   dimmed: f.state == .resolving || f.state == .unknown,
                   italic: f.state == .resolving,
                   pending: snap.phase == .pending,
                   down: f.down, up: f.up,
                   scale: flowScale,
                   scheme: scheme)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Measured against the busiest APP, not the busiest row, so a parent bar is
    /// always the longest thing in its own folder and children read as parts of it.
    private var flowScale: Int64 {
        max(snap.groups.map(\.total).max() ?? 1, 1)
    }

    /// Four columns, matching NetRowView's geometry exactly. App and destination
    /// share the first one -- that is what the nesting encodes.
    private var flowColumnHeader: some View {
        HStack(spacing: 0) {
            Text("APP \u{203a} WENT TO")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("CHART")
                .frame(width: NetRowView.barWidth, alignment: .leading)
                .padding(.horizontal, 5)
            Text("DOWN").frame(width: 58, alignment: .trailing)
            Text("UP").frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        // 8 over, 6 under -- the Battery tab's column header exactly. It had
        // neither, which was survivable while a section title sat above it and
        // wrong the moment that went: the labels ended up resting on the rule.
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Centred, not tucked into the top-left corner. On every open this occupies
    /// most of the pane for the first few seconds, so it is the composition the
    /// user sees -- a line of grey text pinned to one corner of a large void
    /// looks like something failed to load.
    private func inlineNote(_ text: String, icon: String? = nil) -> some View {
        VStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: 18, weight: .light))
                    .foregroundStyle(.quaternary)
            }
            Text(text)
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: the quiet state

    /// `.empty` is a real answer, not a failure: deltas are arriving and they are
    /// all zero. It says so, and keeps the elapsed clock visible in the header so
    /// it reads as "still watching" rather than "stuck".
    private var quietState: some View {
        VStack(spacing: 7) {
            Spacer()
            Image(systemName: "wifi").font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Nothing talked to the network")
                .font(.system(size: 12))
            Text(NetStore.shared.isToday
                 ? "Nothing has moved yet today.\nvitals is recording, so anything that does will appear here."
                 : "No traffic was recorded on this day.\nThe Mac was off, or this day is older than anything kept.")
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: footer

    /// The day's totals. The Battery tab's footer carries that day's used and
    /// gained; this is the same row for the same reason -- a number that sums
    /// the whole day belongs under the whole day, not above it.
    private var footer: some View {
        HStack(spacing: 12) {
            if isUnavailable {
                Text("\u{2014}").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                totalChip(systemImage: "arrow.down", value: snap.totalDown,
                          color: NetPalette.down(scheme), label: "down")
                totalChip(systemImage: "arrow.up", value: snap.totalUp,
                          color: NetPalette.up(scheme), label: "up")
                if !snap.flows.isEmpty {
                    Text("\(snap.groups.count) apps \u{00b7} \(snap.hostCount) hosts")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func totalChip(systemImage: String, value: Int64,
                           color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(NetFormat.bytes(value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    /// What the badge in front of each app name means.
    ///
    /// On screen rather than in a tooltip because a glyph nobody can decode is
    /// decoration, and the one that matters most -- a crossed seal against
    /// something claiming to be a known app -- is the one a person is least
    /// likely to hover over first. Apple and App Store share a shape and differ
    /// only in tint, which is exactly the pair this row exists to disambiguate.
    ///
    /// The wording says who signed it, never whether it is safe. A signature
    /// establishes identity and that the binary is unmodified; notarised
    /// malware exists.
    private var signatureLegend: some View {
        HStack(spacing: 9) {
            ForEach(SigningKind.allCases, id: \.rawValue) { k in
                HStack(spacing: 3) {
                    Image(systemName: k.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(k.tint)
                    Text(k.short)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .help(k.words)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: footnote

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }

    /// The ownership caveat, in plain words: a name is who owns the address
    /// block, not the site that was visited. It is not a disclaimer to bury -- someone
    /// reading "Google LLC" will otherwise assume it means they were on Google.
    private var footnote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 9))
                .foregroundStyle(.secondary)
            // Height is pinned rather than derived. `fixedSize(vertical:)` here
            // makes the whole pane grow to thousands of points: the hosting view
            // sizes itself with no width to wrap against, the text folds to one
            // word per line, and that height is what the window adopts. Every
            // other block in this pane has a definite height, so this one does too.
            Text("These are the machines your Mac connected to, not the pages you read. Browsers look up addresses over an encrypted connection now, so a name here is whoever answered at the other end — and one shared server can front many different sites.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 34, alignment: .top)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

// =====================================================================
// MARK: - One row
// =====================================================================

/// Name, a magnitude bar, then both figures as text. The bar gives the shape of
/// the table at a glance; the numbers are what someone actually reads, so they
/// are never replaced by the bar.
private struct NetRowView: View {
    static let barWidth: CGFloat = 76
    /// The signing badge sits immediately before the app name, between the
    /// disclosure control and the text, rather than in a column of its own.
    ///
    /// It still lines up down the pane -- every parent row has the same
    /// disclosure width and the same leading, so the badges form a column
    /// anyway -- but it now reads as part of the app's own label, which is
    /// what it describes. The width is fixed so the names stay aligned across
    /// glyphs of different widths.
    static let badgeWidth: CGFloat = 13
    /// Pinned rather than left to the text metrics, so a section frame can be an
    /// exact multiple of it and never cut a row in half.
    static let rowHeight: CGFloat = 19
    /// How far a destination's name sits to the right of its app's name.
    ///
    /// A step, not an absolute position. Moving the badge in front of the name
    /// pushed the parent's text right by the badge's width, so a child laid out
    /// from the row's own leading edge ended up LEFT of the app it belongs to
    /// -- nesting drawn upside down. `childLead` derives the child's offset
    /// from the parent's geometry instead, so the two cannot drift apart again.
    /// Zero: a destination's name starts exactly where its app's name starts.
    ///
    /// The nesting is already unambiguous without a step. A child only ever
    /// appears directly under an open folder, it carries no disclosure control
    /// and no badge, and it is set in regular weight against the parent's
    /// medium. Any indent on top of that was buying nothing and spending the
    /// name column -- which is the one column here that runs out of room.
    static let indent: CGFloat = 0
    /// Width of the disclosure control's slot.
    static let disclosureWidth: CGFloat = 11
    /// The HStack's spacing, needed here because the child's leading pad has to
    /// account for the gaps the parent's controls sit in.
    static let gap: CGFloat = 4
    /// Everything a parent row puts before its name, plus one nesting step.
    static var childLead: CGFloat {
        disclosureWidth + gap + badgeWidth + indent
    }

    /// App name on a parent row, destination name on a child row. The two live in
    /// one hierarchical column -- that is what makes this a tree rather than a
    /// table with a repeated first cell.
    let name: String
    let detail: String
    /// nil on a child row; on a parent it is the disclosure state and the row
    /// becomes clickable.
    var expanded: Bool? = nil
    var child: Bool = false
    /// The destination name is not settled (resolving, or the ladder's floor).
    var dimmed: Bool = false
    var italic: Bool = false
    /// A word after the name for a row that is not an ordinary one -- "exited".
    /// Visible, because a tooltip is not a state.
    var tag: String? = nil
    /// nil on a child row.
    var signing: SigningVerdict? = nil
    let pending: Bool
    let down: Int64
    let up: Int64
    /// Largest app total in the tree. EVERY bar is measured against this one
    /// number, parents and children alike, so a child bar can be compared with
    /// any other row on screen. Rescaling each group to its own maximum would
    /// make a quiet app's single destination look as loud as the busiest app.
    let scale: Int64
    let scheme: ColorScheme
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NetRowView.gap) {
                if child {
                    Color.clear.frame(width: NetRowView.childLead, height: 1)
                } else {
                    // A plus/minus box, not a chevron. The chevron rhymed with
                    // the one in the day picker above it, which points at a
                    // menu rather than at a subtree; a boxed plus is the older
                    // and less ambiguous mark for "there is more inside this".
                    Image(systemName: (expanded ?? true) ? "minus.square" : "plus.square")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: NetRowView.disclosureWidth)
                        .opacity(expanded == nil ? 0 : 1)
                    badge.frame(width: NetRowView.badgeWidth, alignment: .leading)
                }
                Text(name)
                    .font(.system(size: 11, weight: child ? .regular : .medium).italic(italic))
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1).truncationMode(.middle)
                if let tag {
                    Text(tag).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            bar.frame(width: NetRowView.barWidth, height: 5).padding(.horizontal, 5)

            Text(pending ? "\u{2014}" : NetFormat.bytes(down))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(pending ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(down == 0 ? .tertiary : .primary))
                .frame(width: 58, alignment: .trailing)

            Text(pending ? "\u{2014}" : NetFormat.bytes(up))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(pending ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(up == 0 ? .tertiary : .primary))
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: NetRowView.rowHeight)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
        .help(detail)
    }

    /// Who signed the app, as one glyph.
    ///
    /// Identity, not a verdict -- see CodeSignature.swift. An app that has never
    /// been seen running draws a dotted outline rather than nothing at all,
    /// because "not checked" and "checked and fine" must not look the same.
    @ViewBuilder private var badge: some View {
        if let signing, !child {
            Image(systemName: signing.kind.symbol)
                .font(.system(size: 9))
                .foregroundStyle(signing.kind.tint)
                .help(signing.tooltip)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// Down then up, left to right, both anchored to the same left baseline, with
    /// a 2pt gap of surface between them so two adjacent fills never read as one.
    private var bar: some View {
        GeometryReader { geo in
            let unit = geo.size.width / CGFloat(max(scale, 1))
            let d = pending ? 0 : segment(CGFloat(down) * unit, down)
            let u = pending ? 0 : segment(CGFloat(up) * unit, up)
            HStack(spacing: d > 0 && u > 0 ? 2 : 0) {
                if d > 0 {
                    Capsule().fill(NetPalette.down(scheme)).frame(width: d)
                }
                if u > 0 {
                    Capsule().fill(NetPalette.up(scheme)).frame(width: u)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 5)
        }
    }

    /// A row that moved one byte still gets a visible mark; a row that moved none
    /// gets nothing at all, so "zero" and "nearly zero" do not look the same.
    private func segment(_ w: CGFloat, _ value: Int64) -> CGFloat {
        value <= 0 ? 0 : max(w, 2.5)
    }
}
