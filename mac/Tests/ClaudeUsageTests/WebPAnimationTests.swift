import XCTest
import libwebp
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

    // MARK: frame geometry — the 1px-shift-on-frame-2 investigation

    /// Each ANMF chunk's frame rectangle: (x, y, w, h) in canvas pixels.
    /// WebP stores x/y halved (offsets must be even), so x/y here are *2.
    private func anmfRects(_ data: Data) -> [(x: Int, y: Int, w: Int, h: Int)] {
        let bytes = [UInt8](data)
        var rects: [(Int, Int, Int, Int)] = []
        var i = 12   // skip RIFF <size> WEBP
        while i + 8 <= bytes.count {
            let fourcc = String(decoding: bytes[i..<i + 4], as: UTF8.self)
            let size = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8
                | Int(bytes[i + 6]) << 16 | Int(bytes[i + 7]) << 24
            if fourcc == "ANMF", i + 8 + 16 <= bytes.count {
                let p = i + 8
                let x = (Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16) * 2
                let y = (Int(bytes[p + 3]) | Int(bytes[p + 4]) << 8 | Int(bytes[p + 5]) << 16) * 2
                let w = (Int(bytes[p + 6]) | Int(bytes[p + 7]) << 8 | Int(bytes[p + 8]) << 16) + 1
                let h = (Int(bytes[p + 9]) | Int(bytes[p + 10]) << 8 | Int(bytes[p + 11]) << 16) + 1
                rects.append((x, y, w, h))
            }
            i += 8 + size + (size & 1)
        }
        return rects
    }

    /// Decode with libwebp's own animation decoder, returning full 64x32 canvases.
    private func decode(_ data: Data) throws -> [[UInt8]] {
        try data.withUnsafeBytes { raw -> [[UInt8]] in
            var webpData = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                                    size: data.count)
            var options = WebPAnimDecoderOptions()
            guard WebPAnimDecoderOptionsInit(&options) != 0 else {
                throw WebPAnimationError.optionsInitFailed
            }
            options.color_mode = MODE_RGBA
            guard let decoder = WebPAnimDecoderNew(&webpData, &options) else {
                throw WebPAnimationError.encoderAllocFailed
            }
            defer { WebPAnimDecoderDelete(decoder) }
            var frames: [[UInt8]] = []
            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                var buffer: UnsafeMutablePointer<UInt8>?
                var timestamp: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &buffer, &timestamp) != 0,
                      let buffer else {
                    throw WebPAnimationError.assembleFailed
                }
                frames.append(Array(UnsafeBufferPointer(start: buffer, count: 64 * 32 * 4)))
            }
            return frames
        }
    }

    /// Two frames identical except the top rows — exactly the shape of the real
    /// animation, where only the reset row alternates.
    private func topRowVariantFrames() -> [[UInt8]] {
        let base = frame(r: 200, g: 50, b: 40)
        var variant = base
        for y in 0..<6 {
            for x in 0..<40 {   // odd-ish region, like text of a different width
                let offset = (y * 64 + x) * 4
                variant[offset] = 30; variant[offset + 1] = 90; variant[offset + 2] = 220
            }
        }
        return [base, variant]
    }

    /// Lossless means the decoder must reproduce our input EXACTLY — any
    /// composition offset bug in our encoding shows up here as a pixel diff.
    func testFramesRoundTripPixelExactly() throws {
        let frames = topRowVariantFrames()
        let data = try WebPAnimation.encode(frames: frames, width: 64, height: 32,
                                            frameDurationMs: 2500)
        let decoded = try decode(data)
        XCTAssertEqual(decoded.count, frames.count)
        for (index, original) in frames.enumerated() {
            XCTAssertEqual(decoded[index], original, "frame \(index) not bit-exact")
        }
    }

    /// Regression test for the on-device 1px shift: every frame must be a
    /// full-canvas rectangle. Left to its defaults the encoder ships frame 2 as
    /// a cropped delta (verified: 40x6 for these frames) — bit-exact by our own
    /// decode, but the panel's decoder composites it a pixel off. Sub-rectangle
    /// frames reappearing here means the kmax setting regressed.
    func testEveryFrameIsAFullCanvasRectangle() throws {
        let data = try WebPAnimation.encode(frames: topRowVariantFrames(),
                                            width: 64, height: 32, frameDurationMs: 2500)
        let rects = anmfRects(data)
        XCTAssertEqual(rects.count, 2)
        for (index, rect) in rects.enumerated() {
            XCTAssertEqual(rect.x, 0, "frame \(index) x offset")
            XCTAssertEqual(rect.y, 0, "frame \(index) y offset")
            XCTAssertEqual(rect.w, 64, "frame \(index) width")
            XCTAssertEqual(rect.h, 32, "frame \(index) height")
        }
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
