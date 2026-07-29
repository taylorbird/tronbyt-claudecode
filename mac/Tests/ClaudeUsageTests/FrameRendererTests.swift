import XCTest
@testable import ClaudeUsage

final class FrameRendererTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_767_225_600)

    private func snapshot(_ percents: [(String, Int)], resetsIn: TimeInterval = 3600)
        -> UsageSnapshot {
        UsageSnapshot(limits: percents.map {
            UsageLimit(label: $0.0, percent: $0.1, resetsAt: anchor.addingTimeInterval(resetsIn))
        })
    }

    private func render(_ snapshot: UsageSnapshot, tier: Staleness.Tier = .fresh,
                        resetRow: FrameRenderer.ResetRow = .session) -> [UInt8] {
        FrameRenderer.render(snapshot: snapshot, tier: tier, fetchedAt: anchor,
                             resetRow: resetRow, now: anchor)
    }

    private func colours(in pixels: [UInt8]) -> Set<[UInt8]> {
        var found = Set<[UInt8]>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            found.insert(Array(pixels[index..<(index + 3)]))
        }
        return found
    }

    private func contains(_ pixels: [UInt8], _ colour: RGBA) -> Bool {
        colours(in: pixels).contains([colour.r, colour.g, colour.b])
    }

    // MARK: colour thresholds — same as pct_color in claude_usage.star

    func testColourThresholds() {
        XCTAssertEqual(FrameRenderer.colour(forPercent: 0), Palette.green)
        XCTAssertEqual(FrameRenderer.colour(forPercent: 49), Palette.green)
        XCTAssertEqual(FrameRenderer.colour(forPercent: 50), Palette.amber)
        XCTAssertEqual(FrameRenderer.colour(forPercent: 79), Palette.amber)
        XCTAssertEqual(FrameRenderer.colour(forPercent: 80), Palette.red)
        XCTAssertEqual(FrameRenderer.colour(forPercent: 100), Palette.red)
    }

    // MARK: countdown formatting — same as countdown_text in claude_usage.star

    func testCountdownFormatting() {
        XCTAssertEqual(FrameRenderer.countdownText(90 * 60), "1H30M")
        XCTAssertEqual(FrameRenderer.countdownText(5 * 60), "0H05M")
        XCTAssertEqual(FrameRenderer.countdownText(25 * 3600), "1D")
        XCTAssertEqual(FrameRenderer.countdownText(6 * 86400), "6D")
    }

    func testCountdownClampsNegativeRatherThanRenderingAMinusSign() {
        XCTAssertEqual(FrameRenderer.countdownText(-500), "0H00M")
    }

    func testMinutesAreZeroPaddedSoTheRowWidthIsStable() {
        XCTAssertEqual(FrameRenderer.countdownText(60 * 60 + 60), "1H01M")
    }

    // MARK: buffer shape

    func testOutputIsExactlyOneRGBAFrame() {
        let pixels = render(snapshot([("5H", 48), ("WK", 23), ("FA", 2)]))
        XCTAssertEqual(pixels.count, 64 * 32 * 4)
    }

    // MARK: rings

    func testZeroPercentDrawsTrackButNoFill() {
        let pixels = render(snapshot([("5H", 0), ("WK", 0), ("FA", 0)]))
        XCTAssertTrue(contains(pixels, Palette.track), "expected an unfilled track")
    }

    func testFullRingLeavesNoTrackPixels() {
        // At 100% every ring step is filled, so no track colour should survive.
        let pixels = render(snapshot([("5H", 100), ("WK", 100), ("FA", 100)]))
        XCTAssertFalse(contains(pixels, Palette.track),
                       "a 100% ring should have no unfilled track left")
    }

    func testPercentageColourAppearsInTheFrame() {
        XCTAssertTrue(contains(render(snapshot([("5H", 10), ("WK", 10), ("FA", 10)])),
                               Palette.green))
        XCTAssertTrue(contains(render(snapshot([("5H", 60), ("WK", 60), ("FA", 60)])),
                               Palette.amber))
        XCTAssertTrue(contains(render(snapshot([("5H", 85), ("WK", 85), ("FA", 85)])),
                               Palette.red))
    }

    // MARK: staleness — the promise this whole rewrite exists to keep

    /// The single most important assertion in the renderer: a dead frame must not
    /// contain ANY colour that signals a live reading. If green/amber/red survives,
    /// stale numbers are being presented as current.
    func testDeadFrameContainsNoLiveColoursAtAll() {
        let pixels = render(snapshot([("5H", 48), ("WK", 23), ("FA", 2)]), tier: .dead)
        for colour in Palette.liveColours {
            XCTAssertFalse(contains(pixels, colour),
                           "a stale frame must not show live colour \(colour)")
        }
        XCTAssertTrue(contains(pixels, Palette.grey), "expected the grey variant")
    }

    /// Even at an alerting percentage — the red border must not reintroduce a live
    /// signal onto a frame whose numbers are known to be old.
    func testDeadFrameStaysGreyEvenWhenAlerting() {
        let pixels = render(snapshot([("5H", 95), ("WK", 91), ("FA", 2)]), tier: .dead)
        for colour in Palette.liveColours {
            XCTAssertFalse(contains(pixels, colour))
        }
    }

    func testWarningTierKeepsLiveColoursAndAddsAnAmberBorder() {
        let pixels = render(snapshot([("5H", 10), ("WK", 10), ("FA", 10)]), tier: .warning)
        XCTAssertTrue(contains(pixels, Palette.green), "numbers stay live at warning tier")
        XCTAssertTrue(contains(pixels, Palette.amber), "expected the amber staleness border")
    }

    // MARK: borders

    /// Sample the BOTTOM-left corner, not the top-left: the reset row draws "5H"
    /// starting at (0,0), so the top-left corner is text rather than border. The
    /// bottom row is only ever border or background.
    private func bottomLeftCorner(_ pixels: [UInt8]) -> [UInt8] {
        let index = ((FrameRenderer.height - 1) * FrameRenderer.width) * 4
        return Array(pixels[index..<(index + 3)])
    }

    func testAlertBorderAppearsAtNinetyPercent() {
        let pixels = render(snapshot([("5H", 90), ("WK", 10), ("FA", 2)]))
        XCTAssertEqual(bottomLeftCorner(pixels),
                       [Palette.red.r, Palette.red.g, Palette.red.b])
    }

    func testNoBorderWhenHealthyAndFresh() {
        let pixels = render(snapshot([("5H", 10), ("WK", 10), ("FA", 2)]))
        XCTAssertEqual(bottomLeftCorner(pixels), [0, 0, 0],
                       "expected no border on a healthy fresh frame")
    }

    /// A scoped limit hitting 90% must NOT trigger the alert border — only the real
    /// session and weekly limits gate work, matching claude_usage.star.
    func testScopedLimitDoesNotTriggerTheAlertBorder() {
        let pixels = render(snapshot([("5H", 10), ("WK", 10), ("FA", 95)]))
        XCTAssertEqual(bottomLeftCorner(pixels), [0, 0, 0])
    }

    // MARK: layout variants

    func testTwoLimitsRenderWithoutCrashing() {
        let pixels = render(snapshot([("5H", 48), ("WK", 23)]))
        XCTAssertEqual(pixels.count, 64 * 32 * 4)
        XCTAssertTrue(contains(pixels, Palette.green))
    }

    func testEmptySnapshotProducesABlankFrameRatherThanCrashing() {
        let pixels = render(UsageSnapshot(limits: []))
        XCTAssertEqual(pixels.count, 64 * 32 * 4)
    }

    func testResetRowAlternatesBetweenSessionAndWeekly() {
        let data = snapshot([("5H", 48), ("WK", 23), ("FA", 2)])
        let sessionFrame = render(data, resetRow: .session)
        let weeklyFrame = render(data, resetRow: .weekly)
        XCTAssertNotEqual(sessionFrame, weeklyFrame,
                          "the two animation frames must differ, or nothing animates")
    }
}
