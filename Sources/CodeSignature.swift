import Foundation
import Security
import SwiftUI

// =============================================================================
// CodeSignature -- who signed the thing that talked to the network.
//
// WHAT THIS CAN AND CANNOT TELL YOU, because the badge is worthless if it is
// read as more than it is:
//
//   It answers "who signed this, and is the binary still exactly what they
//   signed". It does NOT answer "is this safe" or "is this legitimate".
//   Developer ID means Apple knows who the developer is and revoked nothing;
//   notarised malware exists, and has shipped. Treat the badge as identity, not
//   as a verdict -- an unexpected UNSIGNED beside something claiming to be a
//   well-known app is worth a look, and that is the whole of what it is for.
//
// TWO WAYS IN, IN THIS ORDER, AND THE ORDER IS THE WHOLE DESIGN.
//
//   1. THE LIVE PROCESS, by pid. Costs 1.15ms, measured here over 40 processes,
//      because the kernel already validated the running code and kept the
//      answer. Only usable while the process still exists.
//   2. THE EXECUTABLE PATH, from the `proc` identity table (vitals
//      CONTRACT §4). Costs 42.15ms, because SecStaticCodeCheckValidity re-hashes
//      the binary. Usable forever, including for a process that exited months
//      ago.
//
// 37x is why the live check is tried first for every candidate before any path
// is touched, and why nothing here may run on the main thread.
//
// The path route is new; before it, a net row carried only a display name and a
// pid, so anything that had exited could never be checked at all, and the
// short-lived tools that make up a third of a day's table -- ssh, gh, whois,
// uv, git-remote-http -- were permanently unlabelled. They are rarely alive when
// someone opens a panel, which is exactly why remembering the answer by name
// never reached them.
//
// THE NAME-KEYED CACHE STAYS regardless. It is the only thing that can label a
// day recorded before the side table existed, and those days stay in the store
// for a fortnight.
//
// THE JOIN IS BY TIME. A pid is not an identity -- pids recycle -- so a row's
// path is the `proc` entry with the greatest `started` at or before that
// row's timestamp, and a pid with no such entry gets no path at all. The same
// reasoning already governs the live check, via RunningProcesses below.
// =============================================================================

enum SigningKind: String, Codable, CaseIterable {
    case appleSystem      // Apple's own platform binaries
    case appStore         // Mac App Store
    case developerID      // Developer ID, i.e. signed by a known developer
    case adHoc            // signed, but by nobody in particular -- local builds
    case unsigned         // no valid signature at all
    case unknown          // never seen running, so never checked

    /// One family -- the seal -- for every state that IS an answer.
    ///
    /// The Apple logo used to stand in for Apple-signed. It is a different
    /// visual language from the seals and a visibly different width, so a
    /// column of mostly-Apple rows read as ragged next to the ticks. Fill
    /// versus outline now carries the distinction the shape used to, and the
    /// two cases it collapses -- Apple's own software and the App Store -- are
    /// the two that need telling apart least: both are unambiguously fine, and
    /// the tooltip names which is which.
    ///
    /// The distinctions that matter keep distinct shapes: a tick for signed, a
    /// bare seal for ad-hoc, a crossed seal for unsigned. Only "not checked"
    /// sits outside the family, deliberately -- it is the absence of an answer
    /// rather than one of them.
    var symbol: String {
        switch self {
        case .appleSystem:  return "checkmark.seal.fill"
        case .appStore:     return "checkmark.seal.fill"
        case .developerID:  return "checkmark.seal"
        // An empty seal, not a question mark: "questionmark.seal" is not an
        // SF Symbol and rendered as nothing at all, which made ad-hoc look
        // identical to a row with no badge. The missing tick is the message.
        case .adHoc:        return "seal"
        case .unsigned:     return "xmark.seal.fill"
        case .unknown:      return "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .appleSystem:  return .secondary
        case .appStore:     return .blue
        case .developerID:  return .green
        case .adHoc:        return .orange
        case .unsigned:     return .red
        case .unknown:      return .secondary
        }
    }

    /// Two or three words for the legend. Same rule as `words`: it names the
    /// evidence, so nothing here reads as "safe" or "unsafe".
    var short: String {
        switch self {
        case .appleSystem:  return "Apple"
        case .appStore:     return "App Store"
        case .developerID:  return "Developer ID"
        case .adHoc:        return "Ad-hoc"
        case .unsigned:     return "Unsigned"
        case .unknown:      return "Not checked"
        }
    }

    /// Deliberately describes the evidence, never the trustworthiness.
    var words: String {
        switch self {
        case .appleSystem:  return "Signed by Apple (system software)"
        case .appStore:     return "Signed through the Mac App Store"
        case .developerID:  return "Signed with a Developer ID"
        case .adHoc:        return "Ad-hoc signed — no identified developer"
        case .unsigned:     return "No valid code signature"
        case .unknown:      return "Not checked — no live process and no recorded path"
        }
    }
}

/// One app's verdict, plus what backs it up.
struct SigningVerdict: Codable {
    var kind: SigningKind
    /// Apple Developer Team ID, when the signature carries one.
    var team: String?
    /// The signing identifier, e.g. `com.google.Chrome`.
    var identifier: String?

    var tooltip: String {
        var s = kind.words
        if let identifier { s += "\n" + identifier }
        if let team { s += "\nTeam " + team }
        if kind != .unknown {
            s += "\n\nThis says who signed it and that the binary is unmodified."
            s += "\nIt does not say the software is safe."
        }
        return s
    }
}

// MARK: - Reading a signature

enum CodeSignatureReader {

    private static let appleAnchor: SecRequirement? = requirement("anchor apple")
    /// The Developer ID leaf marker OID. `anchor apple generic` alone also
    /// matches App Store builds, so the specific one has to be tried first.
    private static let devIDAnchor: SecRequirement? = requirement(
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
    private static let appleGeneric: SecRequirement? = requirement("anchor apple generic")

    private static func requirement(_ s: String) -> SecRequirement? {
        var r: SecRequirement?
        return SecRequirementCreateWithString(s as CFString, [], &r) == errSecSuccess ? r : nil
    }

    /// Classify the process currently running as `pid`.
    ///
    /// Returns nil when there is no such process, which the caller must not
    /// confuse with `.unsigned`: "gone" and "unsigned" are entirely different
    /// answers and only one of them is alarming.
    static func verdict(pid: pid_t) -> SigningVerdict? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return nil }

        var kind: SigningKind = .unsigned
        if let r = appleAnchor, SecCodeCheckValidity(code, [], r) == errSecSuccess {
            kind = .appleSystem
        } else if let r = devIDAnchor, SecCodeCheckValidity(code, [], r) == errSecSuccess {
            kind = .developerID
        } else if let r = appleGeneric, SecCodeCheckValidity(code, [], r) == errSecSuccess {
            kind = .appStore
        } else if SecCodeCheckValidity(code, [], nil) == errSecSuccess {
            kind = .adHoc
        }

        // Signing information is read from the static form, but only after the
        // cheap dynamic check above has already settled the classification.
        var team: String?
        var identifier: String?
        var stat: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat {
            var d: CFDictionary?
            if SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &d)
                == errSecSuccess, let dict = d as? [String: Any] {
                team = dict["teamid"] as? String
                identifier = dict["identifier"] as? String
            }
        }
        return SigningVerdict(kind: kind, team: team, identifier: identifier)
    }

    /// Classify the binary at `path`, for a process that is no longer running.
    ///
    /// Returns nil when there is nothing at that path any more -- an upgrade
    /// moved it, a temporary tool deleted itself -- which the caller must not
    /// confuse with `.unsigned`. It is the same distinction `verdict(pid:)`
    /// draws between "gone" and "unsigned", and for the same reason.
    ///
    /// 42.15ms each, measured: this re-hashes the whole binary, where the
    /// dynamic check above reads a validation the kernel already did. Never
    /// call it from the main thread, and never call it for a pid that is still
    /// alive -- that is 37x the price for the same answer.
    static func verdict(path: String) -> SigningVerdict? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var stat: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &stat) == errSecSuccess,
              let stat else { return nil }

        var kind: SigningKind = .unsigned
        if let r = appleAnchor, SecStaticCodeCheckValidity(stat, [], r) == errSecSuccess {
            kind = .appleSystem
        } else if let r = devIDAnchor, SecStaticCodeCheckValidity(stat, [], r) == errSecSuccess {
            kind = .developerID
        } else if let r = appleGeneric, SecStaticCodeCheckValidity(stat, [], r) == errSecSuccess {
            kind = .appStore
        } else if SecStaticCodeCheckValidity(stat, [], nil) == errSecSuccess {
            kind = .adHoc
        }

        var team: String?
        var identifier: String?
        var d: CFDictionary?
        if SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &d)
            == errSecSuccess, let dict = d as? [String: Any] {
            team = dict["teamid"] as? String
            identifier = dict["identifier"] as? String
        }
        return SigningVerdict(kind: kind, team: team, identifier: identifier)
    }
}

// MARK: - Which processes are alive, and since when

/// A pid on its own proves nothing about a row recorded hours ago: pids are
/// reused. The start time is what makes the join sound -- a process that began
/// after the row was written is a different process wearing the same number.
struct RunningProcesses {
    private let started: [pid_t: Date]

    static func snapshot() -> RunningProcesses {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return RunningProcesses(started: [:])
        }
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else {
            return RunningProcesses(started: [:])
        }
        var out: [pid_t: Date] = [:]
        for p in buf.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = p.kp_proc.p_pid
            guard pid > 0 else { continue }
            let tv = p.kp_proc.p_un.__p_starttime
            out[pid] = Date(timeIntervalSince1970:
                Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        }
        return RunningProcesses(started: out)
    }

    /// True when `pid` is alive AND was already running when the row was
    /// written, so the two are the same process rather than a recycled number.
    func isSameProcess(pid: pid_t, asOf rowTime: Date) -> Bool {
        guard let s = started[pid] else { return false }
        return s <= rowTime
    }
}

// MARK: - The index the table reads

/// App display name -> verdict, resolved off the main thread and remembered
/// across runs.
///
/// Only names currently on screen are ever looked up, so the cost is the dozen
/// or two apps in the table rather than the ~560 processes on the machine --
/// which at 1.15ms each would still be well under a second, but there is no
/// reason to pay it.
///
/// Two lookups back it, and the expensive one is the fallback. Every candidate
/// pid is tried live first (1.15ms); only an app that no live pid can answer
/// for falls through to its recorded executable path (42.15ms, because the
/// binary is re-hashed). Both happen on `queue`, never on the main thread.
final class SignatureIndex: ObservableObject {

    static let shared = SignatureIndex()

    @Published private(set) var verdicts: [String: SigningVerdict] = [:]

    private let queue = DispatchQueue(label: "signature-index", qos: .utility)
    private var inFlight: Set<String> = []
    private static let defaultsKey = "SigningVerdicts"

    private init() {
        if let data = UserDefaults.standard.data(forKey: SignatureIndex.defaultsKey),
           let saved = try? JSONDecoder().decode([String: SigningVerdict].self, from: data) {
            verdicts = saved
        }
    }

    /// True while a lookup is outstanding. Only the offscreen render harness
    /// reads this -- it has to know when the table has finished filling in, or
    /// it captures a pane full of "not checked".
    var isResolving: Bool { !inFlight.isEmpty }

    func verdict(for app: String) -> SigningVerdict {
        verdicts[app] ?? SigningVerdict(kind: .unknown, team: nil, identifier: nil)
    }

    /// Paths already classified in this run, so the 42ms hash is paid once per
    /// binary rather than once per app per open. Deliberately NOT persisted: the
    /// name-keyed map above is what survives a restart, and a path that has been
    /// classified once is already in it under its app's name.
    private var byPath: [String: SigningVerdict] = [:]
    /// Paths that answered nothing -- deleted, replaced, unreadable. Remembered
    /// only to stop the next redraw re-hashing them to learn the same nothing.
    private var pathMisses: Set<String> = []

    /// Ask for anything on screen that is not settled yet.
    ///
    /// `candidates` are the pids the store recorded for that app, each with the
    /// last time it was seen writing bytes -- the pid alone is not enough to
    /// join on, see RunningProcesses. That same pair is what the `proc`
    /// lookup needs, because its join is by time too.
    func resolve(_ wanted: [(app: String, candidates: [(pid: pid_t, seen: Date)])]) {
        let todo = wanted.filter { verdicts[$0.app] == nil && !inFlight.contains($0.app) }
        guard !todo.isEmpty else { return }
        for w in todo { inFlight.insert(w.app) }

        queue.async { [weak self] in
            guard let self else { return }
            let running = RunningProcesses.snapshot()
            var found: [String: SigningVerdict] = [:]
            for w in todo {
                for c in w.candidates where running.isSameProcess(pid: c.pid, asOf: c.seen) {
                    if let v = CodeSignatureReader.verdict(pid: c.pid) { found[w.app] = v; break }
                }
            }

            // Everything the live route could not answer, from the path the
            // daemon wrote down. This is the whole point of the side table:
            // these are the rows whose process exited minutes or hours ago, and
            // before it existed they could never be labelled at all.
            //
            // Second pass rather than interleaved, so a table full of running
            // apps never waits behind a 42ms hash for one that is not.
            for w in todo where found[w.app] == nil {
                // Newest sighting first: the most recent path is the one most
                // likely still on disk after an upgrade moved the old one.
                for c in w.candidates.sorted(by: { $0.seen > $1.seen }) {
                    guard let path = VitalsStore.NetPaths.shared.path(pid: c.pid, at: c.seen),
                          !self.pathMisses.contains(path) else { continue }
                    if let cached = self.byPath[path] { found[w.app] = cached; break }
                    if let v = CodeSignatureReader.verdict(path: path) {
                        self.byPath[path] = v
                        found[w.app] = v
                        break
                    }
                    self.pathMisses.insert(path)
                }
            }
            DispatchQueue.main.async {
                for w in todo { self.inFlight.remove(w.app) }
                guard !found.isEmpty else { return }
                // Only settled answers are stored. An app that was not running
                // stays absent rather than being written down as unknown, so
                // the next open tries again instead of caching a non-answer.
                self.verdicts.merge(found) { _, new in new }
                if let data = try? JSONEncoder().encode(self.verdicts) {
                    UserDefaults.standard.set(data, forKey: SignatureIndex.defaultsKey)
                    // Flushed rather than left to the periodic write. This cache
                    // is the only thing that can ever label a row whose process
                    // has since exited, so losing it to an abrupt quit costs
                    // real coverage, not just a little work.
                    UserDefaults.standard.synchronize()
                }
            }
        }
    }
}
