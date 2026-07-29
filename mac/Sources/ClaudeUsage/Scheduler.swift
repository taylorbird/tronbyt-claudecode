import AppKit
import Foundation
import Observation

/// Drives the two loops and reacts to sleep.
///
/// Sleep needs explicit handling because it breaks the derived-staleness model: if
/// the Mac sleeps, nothing is running to push, so the device holds the last
/// full-colour frame indefinitely and cannot mark itself stale. So we push the grey
/// variant on the way down, while we still can.
@MainActor
@Observable
final class Scheduler {

    static let fetchInterval: TimeInterval = 120
    static let pushInterval: TimeInterval = 60

    /// Result of the most recent send, for the menu.
    private(set) var lastPushStatus: String?

    private let client: UsageClient
    private let settings: AppSettings
    private let tronbyt: TronbytClient
    private let clock: () -> Date

    private var fetchTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(client: UsageClient,
         settings: AppSettings,
         tronbyt: TronbytClient = TronbytClient(),
         clock: @escaping () -> Date = Date.init) {
        self.client = client
        self.settings = settings
        self.tronbyt = tronbyt
        self.clock = clock
    }

    func start(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        fetchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.client.fetch()
                try? await Task.sleep(for: .seconds(Self.fetchInterval))
            }
        }
        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pushCurrentFrame()
                try? await Task.sleep(for: .seconds(Self.pushInterval))
            }
        }
        observe(notificationCenter)
    }

    func stop() {
        fetchTask?.cancel()
        pushTask?.cancel()
        fetchTask = nil
        pushTask = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers = []
    }

    private func observe(_ center: NotificationCenter) {
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Synchronously kick off the grey push; the system gives us a short
            // window before suspending.
            MainActor.assumeIsolated { self?.pushSleepFrame() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAfterWake() }
        })
    }

    /// Push the grey variant so the panel stops presenting numbers as current.
    func pushSleepFrame() {
        Task { await send(tierOverride: .dead) }
    }

    /// Fetch and push immediately rather than waiting up to a full interval.
    func refreshAfterWake() {
        Task {
            await client.fetch()
            await pushCurrentFrame()
        }
    }

    func pushCurrentFrame() async {
        await send(tierOverride: nil)
    }

    private func send(tierOverride: Staleness.Tier?) async {
        guard let snapshot = client.snapshot else { return }
        let config = settings.config
        guard config.isConfigured else {
            lastPushStatus = "not configured"
            return
        }
        do {
            let frame = try FrameAnimation.encode(snapshot: snapshot,
                                                  tier: tierOverride ?? client.staleness,
                                                  fetchedAt: client.fetchedAt,
                                                  now: clock())
            let status = try await tronbyt.send(frame: frame, config: config)
            lastPushStatus = "pushed (HTTP \(status))"
        } catch {
            lastPushStatus = String(describing: error)
        }
    }
}
