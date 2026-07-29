import SwiftUI

/// Menu bar only app (LSUIElement). Task 1 scaffold: proves the bundle, the
/// menu bar item, and signing before any real logic exists.
@main
struct ClaudeUsageApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("Claude Usage")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            // Placeholder until UsageClient exists; the real title is the
            // session percentage, tinted by the same thresholds as the Tidbyt.
            Text("5H --")
        }
    }
}
