import Foundation
import libwebp

enum WebPAnimationError: Error, CustomStringConvertible {
    case noFrames
    case frameSizeMismatch(index: Int, expected: Int, got: Int)
    case optionsInitFailed
    case configInitFailed
    case encoderAllocFailed
    case pictureInitFailed
    case pictureImportFailed(index: Int)
    case addFrameFailed(index: Int)
    case assembleFailed

    var description: String {
        switch self {
        case .noFrames:
            return "no frames supplied"
        case let .frameSizeMismatch(index, expected, got):
            return "frame \(index) is \(got) bytes, expected \(expected) (width*height*4)"
        case .optionsInitFailed:
            return "WebPAnimEncoderOptionsInit failed (libwebp ABI mismatch?)"
        case .configInitFailed:
            return "WebPConfigInit failed (libwebp ABI mismatch?)"
        case .encoderAllocFailed:
            return "WebPAnimEncoderNew returned null"
        case .pictureInitFailed:
            return "WebPPictureInit failed (libwebp ABI mismatch?)"
        case let .pictureImportFailed(index):
            return "WebPPictureImportRGBA failed for frame \(index)"
        case let .addFrameFailed(index):
            return "WebPAnimEncoderAdd failed for frame \(index)"
        case .assembleFailed:
            return "WebPAnimEncoderAssemble failed"
        }
    }
}

/// Encodes RGBA frames into an animated WebP, which is the only format the
/// tronbyt push API documents — and which macOS itself cannot produce.
enum WebPAnimation {

    /// - Parameters:
    ///   - frames: RGBA8888 buffers, each exactly `width * height * 4` bytes.
    ///   - frameDurationMs: how long each frame is shown.
    static func encode(frames: [[UInt8]], width: Int, height: Int,
                       frameDurationMs: Int) throws -> Data {
        guard !frames.isEmpty else { throw WebPAnimationError.noFrames }

        // Checked up front: WebPPictureImportRGBA reads width*height*4 bytes and
        // would run off the end of a short buffer, which crashes rather than errors.
        let expected = width * height * 4
        for (index, frame) in frames.enumerated() where frame.count != expected {
            throw WebPAnimationError.frameSizeMismatch(
                index: index, expected: expected, got: frame.count
            )
        }

        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else {
            throw WebPAnimationError.optionsInitFailed
        }
        options.anim_params.loop_count = 0   // 0 == loop forever
        // Every frame a full-canvas key-frame (kmax == 1 means exactly that).
        // By default the encoder ships frame 2 as a cropped delta rectangle of
        // just the changed pixels; our own decode of that is bit-exact, but the
        // panel's decoder composites it a pixel off (observed: the gauges shift
        // 1px on the alternate frame). Full frames leave nothing to composite.
        // Cost at 64x32 lossless is a few hundred bytes.
        options.kmax = 1

        guard let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &options) else {
            throw WebPAnimationError.encoderAllocFailed
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else {
            throw WebPAnimationError.configInitFailed
        }
        // 64x32 pixel art with flat colour regions: lossless is both smaller and
        // exact, and exactness matters because the golden-image test compares bytes.
        config.lossless = 1
        config.quality = 100

        for (index, frame) in frames.enumerated() {
            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else {
                throw WebPAnimationError.pictureInitFailed
            }
            defer { WebPPictureFree(&picture) }
            picture.width = Int32(width)
            picture.height = Int32(height)
            picture.use_argb = 1

            let imported: Int32 = frame.withUnsafeBufferPointer { buffer in
                WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(width * 4))
            }
            guard imported != 0 else {
                throw WebPAnimationError.pictureImportFailed(index: index)
            }

            guard WebPAnimEncoderAdd(encoder, &picture,
                                     Int32(index * frameDurationMs), &config) != 0 else {
                throw WebPAnimationError.addFrameFailed(index: index)
            }
        }

        // A trailing null frame stamps the end timestamp, which is what gives the
        // final frame its duration. Without it the last frame has zero duration.
        guard WebPAnimEncoderAdd(encoder, nil,
                                 Int32(frames.count * frameDurationMs), nil) != 0 else {
            throw WebPAnimationError.addFrameFailed(index: frames.count)
        }

        var output = WebPData()
        WebPDataInit(&output)
        defer { WebPDataClear(&output) }
        guard WebPAnimEncoderAssemble(encoder, &output) != 0 else {
            throw WebPAnimationError.assembleFailed
        }
        guard let bytes = output.bytes else { throw WebPAnimationError.assembleFailed }
        return Data(bytes: bytes, count: output.size)
    }
}
