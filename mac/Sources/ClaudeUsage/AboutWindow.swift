import AppKit
import SwiftUI

/// The About window. Shown from the menu and on "reopen" (double-clicking the
/// app in Finder while it is already running) — a menu bar app is otherwise
/// invisible at that moment, and looking like nothing happened reads as broken.
///
/// AppKit-managed rather than a SwiftUI Window scene because it must be openable
/// from the app delegate's reopen callback, where SwiftUI's openWindow
/// environment action is unreachable.
@MainActor
final class AboutWindow {

    static let shared = AboutWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.title = "About Claude Usage"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {

    /// "1.0 (1)" from the bundle, so this never drifts from what is shipped.
    static func versionText(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.clawd(cellSize: 6))
                .interpolation(.none)
            Text("Claude Usage")
                .font(.title2.bold())
            Text(Self.versionText())
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Shows Claude Code usage in the menu bar and pushes it "
                 + "to a Tronbyt/Tidbyt panel.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(width: 280)
            Text("Settings live in the menu bar menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("github.com/taylorbird/tronbyt-claudecode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(28)
    }
}
