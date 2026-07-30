import Foundation
import Observation

/// The single source of truth for usage state. The menu bar and the frame renderer
/// both read from here, so one fetch feeds both and the menu bar costs no extra
/// API calls.
@MainActor
@Observable
final class UsageClient {

    /// Last successfully fetched data. Deliberately retained across failures —
    /// but always paired with `fetchedAt` so callers can tell how old it is.
    private(set) var snapshot: UsageSnapshot?
    /// When `snapshot` was last successfully fetched. **Only updated on success.**
    private(set) var fetchedAt: Date?
    /// Description of the most recent failure, or nil if the last fetch succeeded.
    private(set) var lastError: String?
    /// True when the *credential* is the problem (missing, denied, rejected) —
    /// i.e. the fix is logging into Claude Code. Unrelated failures (5xx,
    /// network, bad JSON) leave the last known credential state untouched.
    private(set) var credentialProblem = false

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Sent verbatim; the endpoint rejects requests without the beta header.
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.9"

    private let session: URLSession
    private let credential: () throws -> Credential
    private let clock: () -> Date

    init(session: URLSession = .shared,
         credential: @escaping () throws -> Credential = { try CredentialReader.read() },
         clock: @escaping () -> Date = Date.init) {
        self.session = session
        self.credential = credential
        self.clock = clock
    }

    /// Fetch once, now. Task 11 replaces this with proper timers; for the moment it
    /// gives the app a way to populate itself at launch.
    func startInitialFetch() {
        Task { await self.fetch() }
    }

    /// Staleness of the current snapshot, derived rather than assumed.
    var staleness: Staleness.Tier {
        Staleness.tier(fetchedAt: fetchedAt, now: clock())
    }

    func fetch() async {
        do {
            let token = try credential().accessToken
            var request = URLRequest(url: Self.endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                lastError = Self.describe(status: status, body: data)
                if status == 401 || status == 403 { credentialProblem = true }
                return   // NB: snapshot and fetchedAt untouched
            }
            snapshot = try UsageSnapshot(json: data)
            fetchedAt = clock()
            lastError = nil
            credentialProblem = false
        } catch let error as CredentialError {
            lastError = String(describing: error)
            credentialProblem = true
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Turn an HTTP failure into something diagnosable from a menu. The 403 case is
    /// called out because it is a closed dead end that cost a deploy cycle: a
    /// `claude setup-token` token authenticates but lacks the user:profile scope
    /// this endpoint requires.
    static func describe(status: Int, body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        if status == 403, text.contains("user:profile") {
            return "HTTP 403: token lacks the user:profile scope this endpoint "
                + "requires — a `claude setup-token` token cannot read usage"
        }
        if status == 401 {
            return "HTTP 401: credential rejected — is Claude Code still logged in?"
        }
        let detail = text.isEmpty ? "" : ": \(text.prefix(160))"
        return "HTTP \(status)\(detail)"
    }
}
