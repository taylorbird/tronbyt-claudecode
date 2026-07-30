import XCTest
@testable import ClaudeUsage

/// Stubs the network so tests never touch api.anthropic.com.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (status, body) = Self.respond?(request) ?? (200, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class UsageClientTests: XCTestCase {

    private func makeClient(
        credential: @escaping () throws -> Credential = { Credential(accessToken: "fake", expiresAt: nil) },
        clock: @escaping () -> Date = { Date(timeIntervalSince1970: 1_767_225_600) }
    ) -> UsageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return UsageClient(session: URLSession(configuration: config),
                           credential: credential, clock: clock)
    }

    private let healthy = Data("""
    {"limits":[{"kind":"session","percent":48},{"kind":"weekly_all","percent":23}]}
    """.utf8)

    override func tearDown() {
        StubURLProtocol.respond = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testSuccessPopulatesSnapshotAndTimestamp() async {
        StubURLProtocol.respond = { _ in (200, self.healthy) }
        let client = makeClient()
        await client.fetch()
        XCTAssertEqual(client.snapshot?.sessionPercent, 48)
        XCTAssertEqual(client.fetchedAt, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertNil(client.lastError)
    }

    func testSendsTheHeadersTheEndpointRequires() async {
        StubURLProtocol.respond = { _ in (200, self.healthy) }
        await makeClient().fetch()
        let headers = StubURLProtocol.lastRequest?.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers["Authorization"], "Bearer fake")
        XCTAssertEqual(headers["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertEqual(headers["User-Agent"], "claude-code/2.1.9")
    }

    /// THE regression test for the bug that started this rewrite. A failed fetch
    /// must keep the old data but must NOT advance fetchedAt — otherwise stale
    /// numbers look freshly retrieved and get displayed as current.
    func testFailureRetainsSnapshotButDoesNotAdvanceTimestamp() async {
        StubURLProtocol.respond = { _ in (200, self.healthy) }
        let client = makeClient()
        await client.fetch()
        let firstFetch = client.fetchedAt

        StubURLProtocol.respond = { _ in (500, Data("boom".utf8)) }
        await client.fetch()

        XCTAssertEqual(client.snapshot?.sessionPercent, 48, "last good data should survive")
        XCTAssertEqual(client.fetchedAt, firstFetch, "fetchedAt must not move on failure")
        XCTAssertNotNil(client.lastError)
    }

    func testStalenessIsDerivedFromTheLastSuccess() async {
        var now = Date(timeIntervalSince1970: 1_767_225_600)
        StubURLProtocol.respond = { _ in (200, self.healthy) }
        let client = makeClient(clock: { now })
        await client.fetch()
        XCTAssertEqual(client.staleness, .fresh)

        now = now.addingTimeInterval(10 * 60)
        XCTAssertEqual(client.staleness, .warning)

        now = now.addingTimeInterval(60 * 60)
        XCTAssertEqual(client.staleness, .dead)
    }

    func testNeverFetchedIsDeadNotFresh() {
        XCTAssertEqual(makeClient().staleness, .dead)
    }

    func testScopeRejectionIsReportedDiagnosably() async {
        StubURLProtocol.respond = { _ in
            (403, Data(#"{"error":{"message":"does not meet scope requirement user:profile"}}"#.utf8))
        }
        let client = makeClient()
        await client.fetch()
        XCTAssertTrue(client.lastError?.contains("user:profile") == true)
        XCTAssertTrue(client.lastError?.contains("setup-token") == true,
                      "should name the known dead end so it is not retried")
    }

    func testUnauthorizedIsReportedAsACredentialProblem() async {
        StubURLProtocol.respond = { _ in (401, Data()) }
        let client = makeClient()
        await client.fetch()
        XCTAssertTrue(client.lastError?.contains("logged in") == true)
    }

    func testMalformedJSONIsAnErrorAndKeepsPriorSnapshot() async {
        StubURLProtocol.respond = { _ in (200, self.healthy) }
        let client = makeClient()
        await client.fetch()

        StubURLProtocol.respond = { _ in (200, Data("not json".utf8)) }
        await client.fetch()

        XCTAssertEqual(client.snapshot?.sessionPercent, 48)
        XCTAssertNotNil(client.lastError)
    }

    func testCredentialFailureIsReportedWithoutCrashing() async {
        StubURLProtocol.respond = { _ in (200, self.healthy) }
        let client = makeClient(credential: { throw CredentialError.notFound })
        await client.fetch()
        XCTAssertNil(client.snapshot)
        XCTAssertNotNil(client.lastError)
    }

    // MARK: credentialProblem — what raises the menu bar warning triangle

    func testMissingCredentialRaisesCredentialProblem() async {
        let client = makeClient(credential: { throw CredentialError.notFound })
        await client.fetch()
        XCTAssertTrue(client.credentialProblem)
    }

    func testUnauthorizedRaisesCredentialProblem() async {
        StubURLProtocol.respond = { _ in (401, Data()) }
        let client = makeClient()
        await client.fetch()
        XCTAssertTrue(client.credentialProblem)
    }

    func testSuccessClearsCredentialProblem() async {
        StubURLProtocol.respond = { _ in (401, Data()) }
        let client = makeClient()
        await client.fetch()

        StubURLProtocol.respond = { _ in (200, self.healthy) }
        await client.fetch()
        XCTAssertFalse(client.credentialProblem)
    }

    /// A 500 says nothing about the credential either way: it must neither raise
    /// the warning from a clean state nor clear one raised by a real rejection.
    func testUnrelatedFailureLeavesCredentialProblemUntouched() async {
        StubURLProtocol.respond = { _ in (500, Data()) }
        let client = makeClient()
        await client.fetch()
        XCTAssertFalse(client.credentialProblem)

        StubURLProtocol.respond = { _ in (401, Data()) }
        await client.fetch()
        StubURLProtocol.respond = { _ in (500, Data()) }
        await client.fetch()
        XCTAssertTrue(client.credentialProblem, "a 500 must not clear a real rejection")
    }

    func testRecoveryClearsTheError() async {
        StubURLProtocol.respond = { _ in (500, Data()) }
        let client = makeClient()
        await client.fetch()
        XCTAssertNotNil(client.lastError)

        StubURLProtocol.respond = { _ in (200, self.healthy) }
        await client.fetch()
        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.snapshot?.sessionPercent, 48)
    }
}
