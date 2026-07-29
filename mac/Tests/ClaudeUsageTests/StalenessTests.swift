import XCTest
@testable import ClaudeUsage

final class StalenessTests: XCTestCase {

    func testFreshBelowSixMinutes() {
        XCTAssertEqual(Staleness.tier(ageSeconds: 0), .fresh)
        XCTAssertEqual(Staleness.tier(ageSeconds: 359), .fresh)
    }

    func testWarningFromSixMinutes() {
        XCTAssertEqual(Staleness.tier(ageSeconds: 360), .warning)
        XCTAssertEqual(Staleness.tier(ageSeconds: 3599), .warning)
    }

    func testDeadFromSixtyMinutes() {
        XCTAssertEqual(Staleness.tier(ageSeconds: 3600), .dead)
        XCTAssertEqual(Staleness.tier(ageSeconds: 86_400), .dead)
    }

    /// Clock skew between the fetch timestamp and now must not read as staleness.
    func testNegativeAgeIsFresh() {
        XCTAssertEqual(Staleness.tier(ageSeconds: -30), .fresh)
    }

    /// Never having fetched is the worst case, not the best — a nil fetchedAt
    /// defaulting to .fresh would show placeholder numbers as if they were live.
    func testNeverFetchedIsDead() {
        XCTAssertEqual(Staleness.tier(fetchedAt: nil), .dead)
    }

    func testTierFromDatesUsesTheInjectedNow() {
        let now = Date(timeIntervalSince1970: 1_785_266_912)
        XCTAssertEqual(Staleness.tier(fetchedAt: now.addingTimeInterval(-60), now: now), .fresh)
        XCTAssertEqual(Staleness.tier(fetchedAt: now.addingTimeInterval(-600), now: now), .warning)
        XCTAssertEqual(Staleness.tier(fetchedAt: now.addingTimeInterval(-7200), now: now), .dead)
    }

    // Timestamps below are derived by arithmetic from a known anchor so they can
    // be checked by hand: 1767225600 == 2026-01-01T00:00:00Z.
    private static let y2026 = 1_767_225_600.0

    func testAsOfTextIsAFixedWidthClockTime() {
        // anchor + 12h34m
        let date = Date(timeIntervalSince1970: Self.y2026 + 12 * 3600 + 34 * 60)
        let text = Staleness.asOfText(date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, "AS OF 12:34")
        // Must fit the 6px reset row: ~16 characters at ~4px each.
        XCTAssertLessThanOrEqual(text.count, 16)
    }

    func testAsOfTextPadsSingleDigitHours() {
        // anchor + 5h06m — a single-digit hour must still occupy two columns, or
        // the row width shifts between updates.
        let date = Date(timeIntervalSince1970: Self.y2026 + 5 * 3600 + 6 * 60)
        let text = Staleness.asOfText(date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, "AS OF 05:06", "hours must be zero-padded to keep the row stable")
    }

    func testAsOfTextUsesTwentyFourHourClockRegardlessOfLocale() {
        // anchor + 23h59m. A locale-sensitive formatter would render this as
        // "11:59 PM" somewhere, which neither fits nor parses as expected.
        let date = Date(timeIntervalSince1970: Self.y2026 + 23 * 3600 + 59 * 60)
        let text = Staleness.asOfText(date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, "AS OF 23:59")
    }
}
