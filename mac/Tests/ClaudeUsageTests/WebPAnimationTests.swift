import XCTest
@testable import ClaudeUsage

/// Task 2 spike. macOS cannot encode WebP (verified: CGImageDestination lists png
/// and gif, not webp) and the tronbyt push API takes WebP, so the whole design
/// depends on reaching libwebp's animation encoder. These tests prove it.
final class WebPAnimationTests: XCTestCase {

    /// Solid RGBA frame of the given colour, 64x32.
    private func frame(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(64 * 32 * 4)
        for _ in 0..<(64 * 32) {
            pixels.append(contentsOf: [r, g, b, 255])
        }
        return pixels
    }

    private func contains(_ data: Data, _ marker: String) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }

    func testEncodesTwoFrameAnimation() throws {
        let data = try WebPAnimation.encode(
            frames: [frame(r: 255, g: 0, b: 0), frame(r: 0, g: 0, b: 255)],
            width: 64, height: 32, frameDurationMs: 2500
        )

        XCTAssertGreaterThan(data.count, 100, "suspiciously small output")
        // RIFF container header: "RIFF" <size> "WEBP"
        XCTAssertEqual(Array(data[0..<4]), Array("RIFF".utf8), "not a RIFF container")
        XCTAssertEqual(Array(data[8..<12]), Array("WEBP".utf8), "not WebP")
        // Animation requires the extended format (VP8X) plus an ANIM chunk. A
        // still image has neither, so these two assertions are what distinguish
        // "encoded something" from "encoded an animation".
        XCTAssertTrue(contains(data, "VP8X"), "not extended-format WebP")
        XCTAssertTrue(contains(data, "ANIM"), "no ANIM chunk — output is not animated")
        XCTAssertTrue(contains(data, "ANMF"), "no ANMF frame chunk")

        // Opt-in only, for the one thing a unit test cannot check: whether the
        // tronbyt server actually accepts our output. Set TEST_RUNNER_WEBP_DUMP_PATH
        // to write the encoded animation somewhere it can be pushed by hand.
        if let dumpPath = ProcessInfo.processInfo.environment["WEBP_DUMP_PATH"] {
            try data.write(to: URL(fileURLWithPath: dumpPath))
        }
    }

    func testSingleFrameStillProducesValidWebP() throws {
        let data = try WebPAnimation.encode(
            frames: [frame(r: 0, g: 255, b: 0)],
            width: 64, height: 32, frameDurationMs: 2500
        )
        XCTAssertEqual(Array(data[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(Array(data[8..<12]), Array("WEBP".utf8))
    }

    func testRejectsEmptyFrameList() {
        XCTAssertThrowsError(
            try WebPAnimation.encode(frames: [], width: 64, height: 32, frameDurationMs: 2500)
        )
    }

    func testRejectsWrongSizedFrameRatherThanReadingOutOfBounds() {
        // A frame shorter than width*height*4 would otherwise be read past its
        // end by WebPPictureImportRGBA — a crash, not an error. Guard it.
        XCTAssertThrowsError(
            try WebPAnimation.encode(frames: [[0, 0, 0, 255]], width: 64, height: 32,
                                     frameDurationMs: 2500)
        )
    }
}
