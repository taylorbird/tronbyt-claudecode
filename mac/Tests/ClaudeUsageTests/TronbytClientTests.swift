import XCTest
@testable import ClaudeUsage

final class TronbytClientTests: XCTestCase {

    private let config = TronbytConfig(baseURL: "http://10.0.0.1:8100",
                                       deviceID: "device-1",
                                       installationID: "claudeusage",
                                       apiKey: "secret-key")

    private func makeClient() -> TronbytClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return TronbytClient(session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        StubURLProtocol.respond = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testPostsToTheDeviceEndpoint() async throws {
        StubURLProtocol.respond = { _ in (200, Data("WebP received.".utf8)) }
        _ = try await makeClient().send(frame: Data([1, 2, 3]), config: config)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString,
                       "http://10.0.0.1:8100/v0/devices/device-1/push")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    /// The tronbyt API takes the key bare, not as a Bearer token. Getting this wrong
    /// yields a 401 that looks like a bad key rather than a bad header.
    func testSendsTheApiKeyWithoutABearerPrefix() async throws {
        StubURLProtocol.respond = { _ in (200, Data()) }
        _ = try await makeClient().send(frame: Data([1]), config: config)
        let header = StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(header, "secret-key")
    }

    func testBodyCarriesBase64FrameAndInstallationID() async throws {
        StubURLProtocol.respond = { _ in (200, Data()) }
        let frame = Data([0xDE, 0xAD, 0xBE, 0xEF])
        _ = try await makeClient().send(frame: frame, config: config)

        // URLProtocol stubs see httpBodyStream rather than httpBody.
        let body = StubURLProtocol.lastRequest?.httpBodyData ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["installationID"] as? String, "claudeusage")
        XCTAssertEqual(Data(base64Encoded: json?["image"] as? String ?? ""), frame,
                       "image must round-trip through base64 unchanged")
    }

    func testTrailingSlashOnTheBaseURLDoesNotProduceADoubleSlash() async throws {
        StubURLProtocol.respond = { _ in (200, Data()) }
        var trailing = config
        trailing.baseURL = "http://10.0.0.1:8100/"
        _ = try await makeClient().send(frame: Data([1]), config: trailing)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString,
                       "http://10.0.0.1:8100/v0/devices/device-1/push")
    }

    func testNonSuccessStatusThrowsWithTheStatusAndBody() async {
        StubURLProtocol.respond = { _ in (401, Data("bad key".utf8)) }
        do {
            _ = try await makeClient().send(frame: Data([1]), config: config)
            XCTFail("expected a throw")
        } catch let error as TronbytError {
            XCTAssertTrue(error.description.contains("401"))
            XCTAssertTrue(error.description.contains("bad key"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testIncompleteConfigThrowsBeforeMakingARequest() async {
        StubURLProtocol.respond = { _ in (200, Data()) }
        var incomplete = config
        incomplete.apiKey = ""
        do {
            _ = try await makeClient().send(frame: Data([1]), config: incomplete)
            XCTFail("expected a throw")
        } catch let error as TronbytError {
            XCTAssertTrue(error.description.contains("Settings"))
            XCTAssertNil(StubURLProtocol.lastRequest, "must not hit the network")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConfiguredRequiresUrlDeviceAndKey() {
        XCTAssertTrue(config.isConfigured)
        for mutate in [{ (c: inout TronbytConfig) in c.baseURL = "" },
                       { c in c.deviceID = "" },
                       { c in c.apiKey = "" }] {
            var broken = config
            mutate(&broken)
            XCTAssertFalse(broken.isConfigured)
        }
    }
}

extension URLRequest {
    /// URLProtocol receives the body as a stream, so httpBody is nil in stubs.
    var httpBodyData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
