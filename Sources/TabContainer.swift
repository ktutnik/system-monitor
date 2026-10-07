import SwiftUI

/// The two-pane shell the dropdown hosts: underline tabs at the top, the Net
/// pane and the Battery pane below them.
///
/// The selected pane is remembered in `UserDefaults` under
/// `TabPreference.defaultsKey`. It is read once at init -- which is what
/// lets the offscreen render mode force a pane through the volatile argument
/// domain -- and written back only when the segmented control is actually used,
/// so a render never leaves a tab change behind.
struct TabContainer: View {
    private let onQuit: () -> Void
    @State private var tab: String

    init(onQuit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.onQuit = onQuit
        let stored = UserDefaults.standard.string(forKey: TabPreference.defaultsKey)
        _tab = State(initialValue: stored == TabPreference.net ? TabPreference.net
                                                               : TabPreference.battery)
    }

    /// Underline tabs rather than a segmented control.
    ///
    /// The segmented picker was the heaviest chrome in the panel: a filled
    /// capsule pair, centred, in its own band, while every other thing in the
    /// window is left-aligned to the same margin. It also came to rhyme with
    /// the range picker inside the Net pane, so two pill-shaped button groups
    /// sat stacked and competed -- when one is navigation between panes and the
    /// other is a filter within one of them.
    ///
    /// An underline says "you are here" with a 2pt rule and no box, reads at a
    /// glance, aligns with TRAFFIC and the app names below it, and is visually
    /// unrelated to anything inside a pane.
    private var tabBar: some View {
        HStack(spacing: 18) {
            tabButton("Net", TabPreference.net)
            tabButton("Battery", TabPreference.battery)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // The panel has a rounded top corner right above this; 9pt put the
        // labels against it. The underline sits flush on the divider below,
        // which is the point of the pattern -- the rule and the separator are
        // one line, with the active segment coloured in.
        .padding(.top, 13)
    }

    private func tabButton(_ title: String, _ id: String) -> some View {
        let on = tab == id
        return VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            // The rule is always laid out, clear when inactive, so selecting a
            // tab cannot shift the row's height by 2pt.
            RoundedRectangle(cornerRadius: 1)
                .fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                .frame(height: 2)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { tab = id }
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider().opacity(0.5)

            Group {
                if tab == TabPreference.net {
                    NetView()
                } else {
                    PopoverView(onQuit: onQuit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: tab) { _, new in
            // Only a real selection lands on disk; the initial value never does.
            UserDefaults.standard.set(new, forKey: TabPreference.defaultsKey)
        }
    }
}
