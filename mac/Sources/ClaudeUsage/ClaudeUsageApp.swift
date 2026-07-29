import SwiftUI

/// Menu bar only app (LSUIElement): reads Claude Code's credential, fetches usage,
/// renders the 64x32 frame in-process and pushes it to a tronbyt-server.
///
/// One process. No HTTP server, no helper agents — that whole arrangement is what
/// this replaces.
@main
@MainActor
struct ClaudeUsageApp: App {
    @State private var settings = AppSettings()
    @State private var client = UsageClient()
    @State private var scheduler: Scheduler?

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: client, scheduler: scheduler)
        } label: {
            Text(menuBarTitle)
                .task { startIfNeeded() }
        }

        SwiftUI.Settings {
            SettingsView(settings: settings, scheduler: scheduler)
        }
    }

    private func startIfNeeded() {
        guard scheduler == nil else { return }
        let scheduler = Scheduler(client: client, settings: settings)
        self.scheduler = scheduler
        scheduler.start()
    }

    /// Always the 5-hour figure — it moves fastest and gates the next hour of work,
    /// and a number whose meaning never changes can be read at a glance.
    private var menuBarTitle: String {
        guard client.staleness != .dead, let percent = client.snapshot?.sessionPercent else {
            return "5H --"
        }
        return "5H \(percent)%"
    }
}

private struct MenuContent: View {
    let client: UsageClient
    let scheduler: Scheduler?

    var body: some View {
        if let snapshot = client.snapshot, !snapshot.limits.isEmpty {
            ForEach(snapshot.limits, id: \.label) { limit in
                Text(row(for: limit))
            }
            Divider()
        }

        Text(statusLine)
        if let push = scheduler?.lastPushStatus {
            Text("Tidbyt: \(push)")
        }
        if let error = client.lastError {
            // Truncated: these get long, and a menu is not a log viewer.
            Text(error.prefix(120).description)
        }

        Divider()
        Button("Refresh now") {
            Task { await client.fetch(); await scheduler?.pushCurrentFrame() }
        }
        SettingsLink { Text("Settings…") }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func row(for limit: UsageLimit) -> String {
        guard let resetsAt = limit.resetsAt else { return "\(limit.label)   \(limit.percent)%" }
        return "\(limit.label)   \(limit.percent)%   resets \(FrameRenderer.clockText(resetsAt))"
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

private struct SettingsView: View {
    let settings: AppSettings
    let scheduler: Scheduler?
    @State private var testResult: String?

    var body: some View {
        Form {
            TextField("Server URL", text: Binding(
                get: { settings.baseURL }, set: { settings.baseURL = $0 }
            ))
            .textContentType(.URL)
            TextField("Device ID", text: Binding(
                get: { settings.deviceID }, set: { settings.deviceID = $0 }
            ))
            TextField("Installation ID", text: Binding(
                get: { settings.installationID }, set: { settings.installationID = $0 }
            ))
            // Stored in the Keychain, never in UserDefaults.
            SecureField("API key", text: Binding(
                get: { settings.apiKey }, set: { settings.apiKey = $0 }
            ))

            HStack {
                Button("Send a test frame") {
                    Task {
                        await scheduler?.pushCurrentFrame()
                        testResult = scheduler?.lastPushStatus
                    }
                }
                .disabled(scheduler == nil || !settings.config.isConfigured)
                if let testResult {
                    Text(testResult).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
