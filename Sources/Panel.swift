import AppKit
import SwiftUI

/// A menu-bar dropdown built as a plain borderless panel.
///
/// NSPopover was the obvious choice and the wrong one: on macOS 26 it draws a
/// ~13pt glass border over its own content view, so whatever you put inside loses
/// an edge on all four sides, and the inset is not exposed anywhere you can read
/// it. A panel we place ourselves has no hidden chrome -- the content box is
/// exactly the size we asked for.
final class DropdownPanel {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }     // borderless panels refuse by default
    }

    /// Rounded container that keeps its hairline subtle in both themes.
    ///
    /// `separatorColor` is meant for a line between two lit surfaces; over the dark
    /// popover material it reads as a bright white outline. A layer's borderColor is
    /// also a resolved CGColor, so it does not follow a theme change on its own --
    /// it has to be re-resolved when the appearance changes.
    private final class RoundedContainer: NSView {
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyBorder()
        }
        func applyBorder() {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.borderColor = NSColor(white: dark ? 1 : 0,
                                         alpha: dark ? 0.09 : 0.14).cgColor
        }
    }

    let size: NSSize
    private let panel: KeyPanel
    private let host: NSHostingView<AnyView>
    private var monitors: [Any] = []
    private weak var anchor: NSStatusBarButton?

    var isVisible: Bool { panel.isVisible }
    var contentView: NSView { panel.contentView ?? host }

    /// Type-erases the root so the panel can host any pane -- the tab shell now,
    /// the battery view before it. Keeping the class concrete means no call site
    /// has to spell out a generic parameter.
    init(size: NSSize, root: some View) {
        self.size = size
        let frame = NSRect(origin: .zero, size: size)
        panel = KeyPanel(contentRect: frame,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // material behind, content in front, one rounded mask over both
        let container = RoundedContainer(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.applyBorder()

        let blur = NSVisualEffectView(frame: frame)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        host = NSHostingView(rootView: AnyView(root))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        panel.contentView = container
    }

    /// Anchored under the status item, nudged back on screen if it would hang off
    /// an edge -- an item near the right corner otherwise opens half off the display.
    func show(under button: NSStatusBarButton) {
        anchor = button
        guard let win = button.window,
              let screen = win.screen ?? NSScreen.main else { return }
        let b = win.convertToScreen(button.convert(button.bounds, to: nil))
        let vis = screen.visibleFrame
        var x = b.midX - size.width / 2
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        let y = min(b.minY, vis.maxY) - size.height - 6
        panel.setFrame(NSRect(x: x, y: max(y, vis.minY + 8),
                              width: size.width, height: size.height),
                       display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.09
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    /// Called every time the panel goes away, by whichever route.
    ///
    /// This exists because `close()` is NOT only reached through the status
    /// item: an outside click or Esc goes through this panel's own event
    /// monitors and never touches AppDelegate. Anything that has to stop when
    /// the dropdown stops must hang off here, or it keeps running invisibly for
    /// the rest of the session -- which is exactly what happened when the net
    /// reader kept re-parsing its window every 2s behind a dismissed panel.
    var onClose: (() -> Void)?

    func close() {
        guard panel.isVisible else { return }      // idempotent: both routes may call
        removeMonitors()
        panel.orderOut(nil)
        onClose?()
    }

    // MARK: dismissal

    private func installMonitors() {
        removeMonitors()
        // Clicks elsewhere in this app: let the status item's own click fall through,
        // or toggling it would close and immediately reopen.
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.close(); return nil }   // esc
                return e
            }
            if e.window === self.panel || e.window === self.anchor?.window { return e }
            self.close()
            return e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }
}
