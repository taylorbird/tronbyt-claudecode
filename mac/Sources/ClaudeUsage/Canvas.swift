import Foundation

struct RGBA: Equatable {
    let r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// The palette, matching claude_usage.star so the native renderer looks like what
/// pixlet has been producing.
enum Palette {
    static let green = RGBA(0x4C, 0xAF, 0x50)   // #4CAF50
    static let amber = RGBA(0xFF, 0xC1, 0x07)   // #FFC107
    static let red   = RGBA(0xF4, 0x43, 0x36)   // #F44336
    static let track = RGBA(0x22, 0x22, 0x22)   // #222
    static let label = RGBA(0x88, 0x88, 0x88)   // #888
    static let day   = RGBA(0x4F, 0xC3, 0xF7)   // #4FC3F7, the weekday highlight
    static let white = RGBA(0xFF, 0xFF, 0xFF)
    static let black = RGBA(0, 0, 0)
    /// The dead-staleness colour. Everything becomes this, so a frame with no
    /// green/amber/red anywhere is unambiguously "these numbers are old".
    static let grey  = RGBA(0x55, 0x55, 0x55)

    /// Every colour that signals a live reading. A grey frame must contain none.
    static let liveColours: [RGBA] = [green, amber, red]
}

/// A fixed-size RGBA pixel buffer with the few drawing primitives the panel needs.
/// Deliberately not Core Graphics: everything here is exact integer pixel work, and
/// a CGContext would introduce antialiasing and colour-space conversions that make
/// byte-exact golden-image comparison impossible.
struct Canvas {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int, background: RGBA = Palette.black) {
        self.width = width
        self.height = height
        self.pixels = [UInt8]()
        self.pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(contentsOf: [background.r, background.g, background.b, background.a])
        }
    }

    /// Out-of-bounds writes are dropped rather than trapping: layout arithmetic on a
    /// 64x32 panel goes out of range easily, and a clipped pixel is a cosmetic bug
    /// while a crash takes the whole display down.
    mutating func set(x: Int, y: Int, to colour: RGBA) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let index = (y * width + x) * 4
        pixels[index] = colour.r
        pixels[index + 1] = colour.g
        pixels[index + 2] = colour.b
        pixels[index + 3] = colour.a
    }

    func colour(x: Int, y: Int) -> RGBA {
        let index = (y * width + x) * 4
        return RGBA(pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    mutating func draw(text: String, x: Int, y: Int, colour: RGBA) {
        for (offset, character) in text.uppercased().enumerated() {
            let glyph = PixelFont.glyph(for: character)
            let originX = x + offset * PixelFont.advance
            for (row, bits) in glyph.enumerated() {
                for column in 0..<PixelFont.glyphWidth {
                    // bit 2 is the leftmost pixel
                    if bits & (1 << (PixelFont.glyphWidth - 1 - column)) != 0 {
                        set(x: originX + column, y: y + row, to: colour)
                    }
                }
            }
        }
    }

    /// A 2px-thick ring filled clockwise from 12 o'clock up to `fraction`.
    ///
    /// Ported from ring_pixels() in claude_usage.star, including its quirk that the
    /// first write to a pixel wins — the outer radius is drawn first, so where the
    /// two radii collide the outer colour is kept. Reproducing that matters: it is
    /// what makes the ring look the same as the existing display.
    mutating func drawRing(centreX: Int, centreY: Int, diameter: Int,
                           fraction: Double, fill: RGBA, track: RGBA) {
        let c = Double(diameter - 1) / 2.0
        var written = Set<Int>()
        for radius in [c, c - 1] {
            let steps = Int(radius * 8)
            guard steps > 0 else { continue }
            for step in 0..<steps {
                let f = Double(step) / Double(steps)
                let x = Int(c + radius * sin(f * 2 * .pi) + 0.5)
                let y = Int(c - radius * cos(f * 2 * .pi) + 0.5)
                let key = y * diameter + x
                guard !written.contains(key) else { continue }
                written.insert(key)
                set(x: centreX + x, y: centreY + y, to: f < fraction ? fill : track)
            }
        }
    }
}
