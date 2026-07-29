import XCTest
@testable import ClaudeUsage

/// Parsing only — the Keychain read itself is verified manually, since it depends
/// on a user consent prompt for an item another app owns. All tokens here are fake.
final class CredentialReaderTests: XCTestCase {

    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testParsesNestedShapeClaudeCodeWrites() throws {
        let credential = try CredentialReader.parse(json("""
        {"claudeAiOauth":{"accessToken":"fake-token","refreshToken":"fake-refresh",
         "expiresAt":1767225600000}}
        """))
        XCTAssertEqual(credential.accessToken, "fake-token")
    }

    func testParsesFlatShape() throws {
        let credential = try CredentialReader.parse(json("""
        {"accessToken":"flat-token","expiresAt":1767225600000}
        """))
        XCTAssertEqual(credential.accessToken, "flat-token")
    }

    /// The trap: expiresAt is MILLISECONDS. Read as seconds it lands in the year
    /// 58500, so nothing ever looks expired and a dead token is used forever.
    func testExpiresAtIsInterpretedAsMilliseconds() throws {
        // 1767225600000 ms == 2026-01-01T00:00:00Z
        let credential = try CredentialReader.parse(json("""
        {"claudeAiOauth":{"accessToken":"t","expiresAt":1767225600000}}
        """))
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_767_225_600))
        // The year must be read in UTC: this instant is midnight UTC on Jan 1, so
        // a local-timezone calendar west of Greenwich still reports the prior year.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let year = utc.component(.year, from: credential.expiresAt!)
        XCTAssertEqual(year, 2026, "if this says 58500, milliseconds were read as seconds")
    }

    func testIsExpiredComparesAgainstTheGivenTime() throws {
        let credential = try CredentialReader.parse(json("""
        {"accessToken":"t","expiresAt":1767225600000}
        """))
        XCTAssertFalse(credential.isExpired(now: Date(timeIntervalSince1970: 1_767_225_599)))
        XCTAssertTrue(credential.isExpired(now: Date(timeIntervalSince1970: 1_767_225_601)))
    }

    /// Boundary: exactly at expiry counts as expired, not usable.
    func testExpiryBoundaryIsInclusive() throws {
        let credential = try CredentialReader.parse(json("""
        {"accessToken":"t","expiresAt":1767225600000}
        """))
        XCTAssertTrue(credential.isExpired(now: Date(timeIntervalSince1970: 1_767_225_600)))
    }

    func testMissingExpiryIsNotTreatedAsExpired() throws {
        let credential = try CredentialReader.parse(json("""
        {"accessToken":"t"}
        """))
        XCTAssertNil(credential.expiresAt)
        XCTAssertFalse(credential.isExpired(), "unknown expiry should not block a fetch attempt")
    }

    func testThrowsWhenAccessTokenMissing() {
        XCTAssertThrowsError(try CredentialReader.parse(json(#"{"claudeAiOauth":{}}"#)))
    }

    func testThrowsWhenAccessTokenEmpty() {
        XCTAssertThrowsError(try CredentialReader.parse(json(#"{"accessToken":""}"#)))
    }

    func testThrowsOnNonJSON() {
        XCTAssertThrowsError(try CredentialReader.parse(json("not json at all")))
    }

    func testErrorsDescribeTheFixNotJustTheFailure() {
        XCTAssertTrue(CredentialError.notFound.description.contains("logged in"))
        XCTAssertTrue(CredentialError.accessDenied(-25293).description.contains("Always Allow"))
    }
}
