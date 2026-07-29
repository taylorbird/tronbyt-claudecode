import XCTest
@testable import ClaudeUsage

final class UsageSnapshotTests: XCTestCase {

    /// Read fixtures by source-relative path rather than bundle resources, so the
    /// tests don't depend on how the test target's resource phase is configured.
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    func testParsesThreeLimitsInOrder() throws {
        let snapshot = try UsageSnapshot(json: fixture("usage-healthy"))
        XCTAssertEqual(snapshot.limits.map(\.label), ["5H", "WK", "FA"])
        XCTAssertEqual(snapshot.limits.map(\.percent), [48, 23, 2])
    }

    /// The real payload carries keys we don't model (amber_ladder, tangelo, …) and
    /// more will appear over time. Unknown fields must never break parsing.
    func testToleratesUnknownTopLevelKeys() throws {
        let snapshot = try UsageSnapshot(json: fixture("usage-healthy"))
        XCTAssertEqual(snapshot.limits.count, 3)
    }

    func testScopedLimitLabelComesFromModelDisplayName() throws {
        let snapshot = try UsageSnapshot(json: fixture("usage-healthy"))
        XCTAssertEqual(snapshot.limits[2].label, "FA", "expected first two letters of 'Fable'")
    }

    func testSessionPercentIsTheMenuBarNumber() throws {
        let snapshot = try UsageSnapshot(json: fixture("usage-healthy"))
        XCTAssertEqual(snapshot.sessionPercent, 48)
    }

    func testResetDatesAreParsedIncludingFractionalSeconds() throws {
        let snapshot = try UsageSnapshot(json: fixture("usage-healthy"))
        // Fractional seconds and a +00:00 offset broke a previous implementation.
        XCTAssertNotNil(snapshot.limits[0].resetsAt)
        let year = Calendar(identifier: .gregorian)
            .component(.year, from: snapshot.limits[0].resetsAt!)
        XCTAssertEqual(year, 2026)
    }

    func testFallsBackToFiveHourAndSevenDayWhenLimitsAbsent() throws {
        let json = Data("""
        {"five_hour":{"utilization":12.0},"seven_day":{"utilization":34.0}}
        """.utf8)
        let snapshot = try UsageSnapshot(json: json)
        XCTAssertEqual(snapshot.limits.map(\.label), ["5H", "WK"])
        XCTAssertEqual(snapshot.limits.map(\.percent), [12, 34])
    }

    func testCapsAtThreeLimits() throws {
        let json = Data("""
        {"limits":[
          {"kind":"session","percent":1},{"kind":"weekly_all","percent":2},
          {"kind":"weekly_scoped","percent":3,"scope":{"model":{"display_name":"Opus"}}},
          {"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"Sonnet"}}}
        ]}
        """.utf8)
        let snapshot = try UsageSnapshot(json: json)
        XCTAssertEqual(snapshot.limits.count, 3, "only three gauges fit on a 64x32 panel")
    }

    func testSkipsLimitsWithNoPercent() throws {
        let json = Data("""
        {"limits":[
          {"kind":"session","percent":5},
          {"kind":"weekly_all","percent":null}
        ]}
        """.utf8)
        let snapshot = try UsageSnapshot(json: json)
        XCTAssertEqual(snapshot.limits.map(\.label), ["5H"])
    }

    func testThrowsOnMalformedJSON() {
        XCTAssertThrowsError(try UsageSnapshot(json: Data("not json".utf8)))
    }

    func testEmptyPayloadYieldsNoLimitsRatherThanThrowing() throws {
        let snapshot = try UsageSnapshot(json: Data("{}".utf8))
        XCTAssertTrue(snapshot.limits.isEmpty)
        XCTAssertNil(snapshot.sessionPercent)
    }
}
