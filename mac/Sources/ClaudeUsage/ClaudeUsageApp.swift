import SwiftUI

/// Menu bar only app (LSUIElement).
///
/// Timers, settings and frame pushing arrive in later tasks. Right now this exists
/// to exercise the real Keychain read and usage fetch under the app's own signing
/// identity — which is the only way to verify that path, since a consent grant
/// binds to the requesting binary.
@main
@MainActor
struct ClaudeUsageApp: App {
    @State private var client = UsageClient()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: client)
                .task { client.startInitialFetch() }
        } label: {
            Text(menuBarTitle)
                .task { client.startInitialFetch() }
        }
    }

    /// Always the 5-hour figure: it moves fastest and gates the next hour of work,
    /// and a number whose meaning never changes can be read without thinking.
    private var menuBarTitle: String {
        guard client.staleness != .dead, let percent = client.snapshot?.sessionPercent else {
            return "5H --"
        }
        return "5H \(percent)%"
    }
}

private struct MenuContent: View {
    let client: UsageClient

    var body: some View {
        if let snapshot = client.snapshot, !snapshot.limits.isEmpty {
            ForEach(snapshot.limits, id: \.label) { limit in
                Text("\(limit.label)   \(limit.percent)%\(resetSuffix(limit))")
            }
            Divider()
        }

        Text(statusLine)

        if let error = client.lastError {
            // Truncated: these can be long, and the menu is not a log viewer.
            Text(error.prefix(120).description)
        }

        Divider()
        Button("Refresh now") {
            Task { await client.fetch() }
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func resetSuffix(_ limit: UsageLimit) -> String {
        guard let resetsAt = limit.resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return "   resets \(formatter.string(from: resetsAt))"
    }

    private var statusLine: String {
        guard let fetchedAt = client.fetchedAt else { return "No data yet" }
        switch client.staleness {
        case .fresh:   return Staleness.asOfText(fetchedAt)
        case .warning: return "\(Staleness.asOfText(fetchedAt)) — falling behind"
        case .dead:    return "\(Staleness.asOfText(fetchedAt)) — STALE"
        }
    }
}
