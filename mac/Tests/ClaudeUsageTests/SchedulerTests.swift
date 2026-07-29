import XCTest
@testable import ClaudeUsage

@MainActor
final class SchedulerTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_767_225_600)
    private var suiteName: String!
    private var service: String!

    override func setUp() {
        super.setUp()
        suiteName = "SchedulerTests.\(UUID().uuidString)"
        service = "com.tbird.ClaudeUsage.test.\(UUID().uuidString)"
        StubURLProtocol.respond = { _ in (200, Data("WebP received.".utf8)) }
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? AppSettings.storeAPIKey("", service: service)
        StubURLProtocol.respond = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeAppSettings(configured: Bool = true) -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!,
                                keychainService: service)
        if configured {
            settings.baseURL = "http://10.0.0.1:8100"
            settings.deviceID = "dev"
            settings.apiKey = "key"
        }
        return settings
    }

    /// A client already holding data, without going through the network.
    private func loadedClient() async -> UsageClient {
        let client = UsageClient(session: stubSession(),
                                 credential: { Credential(accessToken: "t", expiresAt: nil) },
                                 clock: { self.anchor })
        StubURLProtocol.respond = { _ in
            (200, Data(#"{"limits":[{"kind":"session","percent":48},{"kind":"weekly_all","percent":23}]}"#.utf8))
        }
        await client.fetch()
        StubURLProtocol.respond = { _ in (200, Data("WebP received.".utf8)) }
        return client
    }

    func testPushSendsAFrameAndRecordsTheStatus() async {
        let scheduler = Scheduler(client: await loadedClient(), settings: makeAppSettings(),
                                  tronbyt: TronbytClient(session: stubSession()),
                                  clock: { self.anchor })
        await scheduler.pushCurrentFrame()
        XCTAssertEqual(scheduler.lastPushStatus, "pushed (HTTP 200)")
        XCTAssertNotNil(StubURLProtocol.lastRequest)
    }

    func testUnconfiguredAppSettingsReportRatherThanSend() async {
        let scheduler = Scheduler(client: await loadedClient(),
                                  settings: makeAppSettings(configured: false),
                                  tronbyt: TronbytClient(session: stubSession()),
                                  clock: { self.anchor })
        StubURLProtocol.lastRequest = nil
        await scheduler.pushCurrentFrame()
        XCTAssertEqual(scheduler.lastPushStatus, "not configured")
        XCTAssertNil(StubURLProtocol.lastRequest, "must not hit the network")
    }

    func testNoDataMeansNoPushAtAll() async {
        // A client that never fetched: pushing a frame built from nothing would put
        // a blank panel up, which is worse than leaving the previous frame.
        let empty = UsageClient(session: stubSession(),
                                credential: { Credential(accessToken: "t", expiresAt: nil) },
                                clock: { self.anchor })
        let scheduler = Scheduler(client: empty, settings: makeAppSettings(),
                                  tronbyt: TronbytClient(session: stubSession()),
                                  clock: { self.anchor })
        StubURLProtocol.lastRequest = nil
        await scheduler.pushCurrentFrame()
        XCTAssertNil(StubURLProtocol.lastRequest)
        XCTAssertNil(scheduler.lastPushStatus)
    }

    /// The sleep path must send the GREY frame even though the data is fresh —
    /// otherwise the panel keeps showing live colours for however long the Mac is
    /// asleep, with nothing running to correct it.
    func testSleepPushSendsTheGreyVariantDespiteFreshData() async throws {
        let client = await loadedClient()
        XCTAssertEqual(client.staleness, .fresh, "precondition: data is fresh")

        var sent: Data?
        StubURLProtocol.respond = { request in
            sent = request.httpBodyData
            return (200, Data())
        }
        let scheduler = Scheduler(client: client, settings: makeAppSettings(),
                                  tronbyt: TronbytClient(session: stubSession()),
                                  clock: { self.anchor })
        scheduler.pushSleepFrame()

        // Let the detached Task complete.
        for _ in 0..<50 where sent == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let body = try XCTUnwrap(sent)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let frame = try XCTUnwrap(Data(base64Encoded: json?["image"] as? String ?? ""))

        // Compare against a deliberately-grey encode of the same data.
        let expected = try FrameAnimation.encode(snapshot: client.snapshot!, tier: .dead,
                                                 fetchedAt: client.fetchedAt, now: anchor)
        XCTAssertEqual(frame, expected, "sleep must push the grey frame, not the live one")

        let live = try FrameAnimation.encode(snapshot: client.snapshot!, tier: .fresh,
                                             fetchedAt: client.fetchedAt, now: anchor)
        XCTAssertNotEqual(frame, live)
    }

    func testFailedSendIsReportedNotSwallowed() async {
        StubURLProtocol.respond = { _ in (500, Data("nope".utf8)) }
        let client = await loadedClient()
        StubURLProtocol.respond = { _ in (500, Data("nope".utf8)) }
        let scheduler = Scheduler(client: client, settings: makeAppSettings(),
                                  tronbyt: TronbytClient(session: stubSession()),
                                  clock: { self.anchor })
        await scheduler.pushCurrentFrame()
        XCTAssertTrue(scheduler.lastPushStatus?.contains("500") == true,
                      "got: \(scheduler.lastPushStatus ?? "nil")")
    }

    func testIntervalsMatchTheDesign() {
        XCTAssertEqual(Scheduler.fetchInterval, 120)
        XCTAssertEqual(Scheduler.pushInterval, 60)
    }
}
