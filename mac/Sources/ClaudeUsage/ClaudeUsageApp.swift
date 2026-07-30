import SwiftUI

/// Menu bar only app (LSUIElement): reads Claude Code's credential, fetches usage,
/// renders the 64x32 frame in-process and pushes it to a tronbyt-server.
///
/// One process. No HTTP server, no helper agents — that whole arrangement is what
/// this replaces.
/// Double-clicking the app in Finder while it is running "reopens" it. For a
/// menu bar app that would otherwise do visibly nothing, so show the About
/// window. (Settings can't be opened programmatically on modern macOS —
/// SettingsLink requires a user interaction context — so About it is, and it
/// points at where Settings live.)
final class ReopenDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { AboutWindow.shared.show() }
        return true
    }
}

@main
@MainActor
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(ReopenDelegate.self) private var reopenDelegate
    @State private var settings = AppSettings()
    @State private var client = UsageClient()
    @State private var scheduler: Scheduler?

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: client, scheduler: scheduler)
        } label: {
            Image(nsImage: MenuBarIcon.image)
            if menuBarState.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(menuBarState.text)
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

    private var menuBarState: MenuBarState {
        MenuBarState.make(sessionPercent: client.snapshot?.sessionPercent,
                          staleness: client.staleness,
                          credentialProblem: client.credentialProblem)
    }
}

private struct MenuContent: View {
    let client: UsageClient
    let scheduler: Scheduler?

    var body: some View {
        // Title row: Clawd + name, rendered by the menu as a disabled header.
        Label {
            Text("Claude Code Usage")
        } icon: {
            Image(nsImage: MenuBarIcon.image)
        }
        .labelStyle(.titleAndIcon)
        Divider()

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
        Button("About Claude Usage") { AboutWindow.shared.show() }
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
    @State private var launchAtLogin = false
    @State private var loginError: String?

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

            Divider()

            Toggle("Start at login", isOn: Binding(
                get: { launchAtLogin },
                set: { wanted in
                    do {
                        try LaunchAtLogin.setEnabled(wanted)
                        launchAtLogin = LaunchAtLogin.isEnabled
                        loginError = nil
                    } catch {
                        loginError = String(describing: error)
                    }
                }
            ))
            .disabled(!LaunchAtLogin.isInStableLocation)

            if !LaunchAtLogin.isInStableLocation {
                Text("Move the app to /Applications to enable this — a login item "
                     + "pointing into a build folder breaks when that folder is cleaned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}
