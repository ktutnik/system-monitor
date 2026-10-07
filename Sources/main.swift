import AppKit
import SwiftUI

/// Which pane the dropdown opens on (the last tab used is remembered).
///
/// `TabContainer` owns the preference; this type exists so the offscreen render
/// mode can force a pane without persisting anything. It writes the key into the
/// *argument* domain, which outranks the standard domain and is discarded when
/// the process exits -- rendering the net pane must not change what the real
/// menu-bar app opens on next time.
enum TabPreference {
    /// Contract with TabContainer.swift -- it must read this exact key.
    static let defaultsKey = "SelectedTab"
    static let battery = "battery"
    static let net = "net"

    /// Both render-only overrides go in ONE call: `setVolatileDomain` replaces
    /// the domain rather than merging into it, so a second call would silently
    /// drop the first one's key.
    static func forceForThisProcess(_ tab: String, expandAll: Bool = false) {
        var d: [String: Any] = [defaultsKey: tab]
        // Both panes are trees now, and one flag opens whichever is captured.
        if expandAll {
            d[NetView.expandAllKey] = true
            d[PopoverView.expandAllKey] = true
        }
        UserDefaults.standard.setVolatileDomain(d, forName: UserDefaults.argumentDomain)
    }
}

/// The app owns an `NSStatusItem` and nothing else while the dropdown is shut:
/// no timers, no run-loop sources, no notification observers.
/// Everything -- sampling, health, the history backfill -- happens in `toggle()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let popoverSize = NSSize(width: 540, height: 620)

    private var statusItem: NSStatusItem!
    private var dropdown: DropdownPanel!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle(_:))
        installStaticIcon()

        dropdown = DropdownPanel(size: AppDelegate.popoverSize,
                                 root: TabContainer(onQuit: { NSApp.terminate(nil) }))
        // Every dismissal route ends here, not just the status-item click, so
        // this is the one place that can promise that nothing runs while the
        // dropdown is shut.
        dropdown.onClose = { NetStore.shared.stop() }

        // Deliberately nothing else. No recordNow(), no refreshHealth(), no
        // backfill() -- launch must cost one status item and return.
    }

    /// One template image, set once. No percentage text beside it: the
    /// system menu bar already shows the battery, and a figure of our own would
    /// need a refresh timer, and nothing may run while the dropdown is shut.
    ///
    /// The symbol has to read as "system activity", not as a battery. The list is
    /// a fallback chain only -- the first entry is the choice.
    private func installStaticIcon() {
        guard let button = statusItem.button else { return }
        let candidates = ["waveform.path.ecg", "chart.bar", "gauge", "network"]
        let image = candidates.lazy.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: "System Monitor")
        }.first
        image?.isTemplate = true        // let macOS tint it: light, dark, highlighted
        button.image = image
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
    }

    /// Opens the real dropdown and writes its own window content to a PNG, so the
    /// live layout can be checked without a screen-recording permission.
    func probeCapture(to path: String) {
        toggle(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let root = self.dropdown.contentView
            guard let win = root.window else { exit(1) }
            NSLog("panel %@ content %@ screen %@",
                  NSStringFromRect(win.frame), NSStringFromRect(root.bounds),
                  NSStringFromRect(NSScreen.main?.visibleFrame ?? .zero))
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    /// The only place any work happens. Opening samples the battery, refreshes
    /// health, and asks the backfill to close whatever gap the store has. The
    /// backfill is cheap now and usually does nothing at all: the daemon records
    /// continuously, so there is normally no gap, and it returns on a timestamp
    /// comparison without spawning anything.
    @objc private func toggle(_ sender: Any?) {
        if dropdown.isVisible {
            dropdown.close()                // onClose stops the reader
            return
        }
        guard let button = statusItem.button else { return }
        NetStore.shared.start()             // sampling begins on open, not before
        let store = HistoryStore.shared
        store.day = Calendar.current.startOfDay(for: Date())
        store.recordNow()
        store.refreshHealth()
        store.reload()
        // Asynchronous regardless: on the rare open where there IS a gap to
        // close this lands after the panel is already up and republishes the day
        // when it finishes.
        store.backfill { store.reload() }
        dropdown.show(under: button)
    }
}

// --render-icon <png>: the battery glyphs at four levels on a bar-like strip.
// The menu bar no longer uses these -- the Battery tab still draws them,
// so this stays as a way to eyeball them.
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    let levels = [100, 62, 35, 12]
    let img = NSImage(size: NSSize(width: 460, height: 30), flipped: false) { _ in
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 460, height: 30).fill()
        var x: CGFloat = 12
        for (n, lvl) in levels.enumerated() {
            let charging = n == 1
            let glyph = BatteryIcon.image(percent: lvl, charging: charging, onAC: charging)
            let title = "\(lvl)% " as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.black]
            title.draw(at: NSPoint(x: x, y: 8), withAttributes: attrs)
            x += title.size(withAttributes: attrs).width
            if glyph.isTemplate {          // template images carry no colour of their own
                let tinted = NSImage(size: glyph.size, flipped: false) { r in
                    glyph.draw(in: r); NSColor.black.set()
                    r.fill(using: .sourceAtop); return true }
                tinted.draw(at: NSPoint(x: x, y: 9), from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                glyph.draw(at: NSPoint(x: x, y: 9), from: .zero, operation: .sourceOver, fraction: 1)
            }
            x += glyph.size.width + 26
        }
        return true
    }
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    print("rendered icons")
    exit(0)
}

// --render <png> [YYYY-MM-DD] [dark] [cal] [net|battery]
//
// Draws the real view offscreen and exits, so the layout can be checked without a
// screen-recording permission. The trailing words are order-free flags:
//   dark          render in dark aqua
//   cal           the Battery tab with its calendar open (battery pane only)
//   net|battery   which tab to capture; battery is the default, matching the
//                 "last tab used" rule on a fresh profile
if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 {
    let out = CommandLine.arguments[i + 1]
    let flags = CommandLine.arguments.dropFirst(i + 2)
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.accessory)

    let store = HistoryStore.shared
    let sem = DispatchSemaphore(value: 0)
    store.backfill { sem.signal() }
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    if let d = flags.compactMap({ f.date(from: $0) }).first {
        store.day = d
        // Both panes are day-based now, so a date on the command line has to
        // reach both or the two tabs render different days in one capture.
        NetStore.shared.day = Calendar.current.startOfDay(for: d)
    }
    store.reload()

    let dark = flags.contains("dark")
    let wantCal = flags.contains("cal")
    let tab = flags.contains(TabPreference.net) ? TabPreference.net : TabPreference.battery
    TabPreference.forceForThisProcess(tab, expandAll: flags.contains("expand"))

    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // `cal` captures the Battery pane on its own -- the calendar is a state of that
    // view, not of the tab shell, so there is nothing to ask TabContainer for.
    let root: AnyView = wantCal
        ? AnyView(PopoverView(openCalendar: true))
        : AnyView(TabContainer(onQuit: {}))
    let host = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
    host.frame = NSRect(origin: .zero, size: AppDelegate.popoverSize)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                       backing: .buffered, defer: false)
    win.contentView = host
    // Offscreen there is nothing to resolve the appearance against, so labels
    // render in the wrong colour unless it is pinned on both window and host.
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.appearance = win.appearance
    win.backgroundColor = .windowBackgroundColor
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    win.setFrameOrigin(NSPoint(x: -5000, y: -5000))
    win.orderFront(nil)
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.2))
    // The signature badges fill in off the main thread, so a fixed settle
    // window captures whichever ones happened to land. Wait for the lookup to
    // drain -- bounded, because a capture that hangs is worse than one that is
    // a little incomplete. Ten seconds rather than three since the path
    // fallback landed: an app with no live process costs a 42ms re-hash of its
    // binary, and a day's table can hold a dozen of them.
    let sigDeadline = Date().addingTimeInterval(10)
    while SignatureIndex.shared.isResolving, Date() < sigDeadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.35))
    host.layoutSubtreeIfNeeded()
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: out))
    }
    print("rendered \(out) [\(tab)\(dark ? ", dark" : "")]")
    exit(0)
}

// The --netprobe / --netcycle modes moved out with the sampler they exercised:
// this app no longer touches NetworkStatistics, so there is nothing here to
// probe. `vitalsd --netprobe` is the equivalent, and it tests the code that
// actually does the sampling now.

let probe = CommandLine.arguments.firstIndex(of: "--probe").map { CommandLine.arguments[$0 + 1] }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // menu bar only: no Dock tile, no menu bar menus

if let out = probe {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        delegate.probeCapture(to: out)
    }
}
app.run()
