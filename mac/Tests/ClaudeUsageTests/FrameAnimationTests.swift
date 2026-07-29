import CryptoKit
import XCTest
@testable import ClaudeUsage

final class FrameAnimationTests: XCTestCase {

    private let anchor = Date(timeIntervalSince1970: 1_767_225_600)

    /// A fixed, realistic snapshot: 48/23/2 with distinct reset times, which is what
    /// the live account actually looked like when this was written.
    private var reference: UsageSnapshot {
        UsageSnapshot(limits: [
            UsageLimit(label: "5H", percent: 48,
                       resetsAt: anchor.addingTimeInterval(80 * 60)),
            UsageLimit(label: "WK", percent: 23,
                       resetsAt: anchor.addingTimeInterval(6 * 86400)),
            UsageLimit(label: "FA", percent: 2,
                       resetsAt: anchor.addingTimeInterval(6 * 86400)),
        ])
    }

    func testProducesTwoDistinctFrames() {
        let frames = FrameAnimation.frames(snapshot: reference, tier: .fresh,
                                           fetchedAt: anchor, now: anchor)
        XCTAssertEqual(frames.count, 2)
        XCTAssertNotEqual(frames[0], frames[1], "the reset row must differ between frames")
    }

    func testCollapsesToASingleFrameWhenBothVariantsWouldMatch() {
        // No weekly limit, so the weekly reset row renders the same as the session
        // one; animating identical frames would flicker for nothing.
        let single = UsageSnapshot(limits: [
            UsageLimit(label: "5H", percent: 10, resetsAt: anchor.addingTimeInterval(600)),
        ])
        let frames = FrameAnimation.frames(snapshot: single, tier: .fresh,
                                           fetchedAt: anchor, now: anchor)
        XCTAssertEqual(frames.count, 1)
    }

    func testEncodesToAnimatedWebP() throws {
        let data = try FrameAnimation.encode(snapshot: reference, tier: .fresh,
                                             fetchedAt: anchor, now: anchor)
        XCTAssertEqual(Array(data[8..<12]), Array("WEBP".utf8))
        XCTAssertNotNil(data.range(of: Data("ANIM".utf8)), "output is not animated")
        XCTAssertGreaterThan(data.count, 100)
    }

    /// Regression tripwire on the rendered pixels rather than the encoded bytes:
    /// hashing the RGBA buffer is stable across libwebp versions, whereas the
    /// compressed output is not. If this changes, the visual output changed — update
    /// it deliberately, after looking at the frame.
    func testRenderedPixelsMatchTheGoldenHash() {
        let frames = FrameAnimation.frames(snapshot: reference, tier: .fresh,
                                           fetchedAt: anchor, now: anchor)
        let digest = SHA256.hash(data: Data(frames[0]))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.goldenSessionFrameHash,
                       "rendered output changed — verify the frame looks right, then update")
    }

    /// Recorded 2026-07-29 after visually confirming the frame renders
    /// "5H 17:20(1H20M)" over three green rings reading 48 / 23 / 2 with 5H / WK / FA
    /// beneath — matching the pixlet output it replaces.
    static let goldenSessionFrameHash =
        "79554a9ddb43bb72f6abaaf93632d9c6323abb360e002de43c5a028aca409aac"

    /// Opt-in: writes the encoded animation so it can be pushed to a real device.
    func testDumpForManualInspection() throws {
        guard let path = ProcessInfo.processInfo.environment["FRAME_DUMP_PATH"] else {
            return
        }
        let data = try FrameAnimation.encode(snapshot: reference, tier: .fresh,
                                             fetchedAt: anchor, now: anchor)
        try data.write(to: URL(fileURLWithPath: path))

        if let greyPath = ProcessInfo.processInfo.environment["FRAME_DUMP_GREY_PATH"] {
            let grey = try FrameAnimation.encode(snapshot: reference, tier: .dead,
                                                 fetchedAt: anchor, now: anchor)
            try grey.write(to: URL(fileURLWithPath: greyPath))
        }
    }
}
