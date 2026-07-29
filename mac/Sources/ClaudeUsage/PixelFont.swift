import Foundation

/// A 3x5 bitmap font, authored here rather than borrowed.
///
/// The panel is 64x32. Text has to be pixel-exact at 5px tall, which rules out
/// Core Graphics text: any real typeface at that size is mush whether or not
/// antialiasing is off. 3 pixels wide plus 1 of spacing gives a 4px advance, so
/// 16 characters fit across the panel.
///
/// Each glyph is 5 rows; the low 3 bits of each row are the pixels, bit 2 leftmost.
enum PixelFont {

    static let glyphWidth = 3
    static let glyphHeight = 5
    /// Width of one character including the gap that follows it.
    static let advance = 4

    /// Rows are top to bottom. 0b101 == pixel, gap, pixel.
    static let glyphs: [Character: [UInt8]] = [
        "0": [0b111, 0b101, 0b101, 0b101, 0b111],
        "1": [0b010, 0b110, 0b010, 0b010, 0b111],
        "2": [0b111, 0b001, 0b111, 0b100, 0b111],
        "3": [0b111, 0b001, 0b111, 0b001, 0b111],
        "4": [0b101, 0b101, 0b111, 0b001, 0b001],
        "5": [0b111, 0b100, 0b111, 0b001, 0b111],
        "6": [0b111, 0b100, 0b111, 0b101, 0b111],
        "7": [0b111, 0b001, 0b001, 0b001, 0b001],
        "8": [0b111, 0b101, 0b111, 0b101, 0b111],
        "9": [0b111, 0b101, 0b111, 0b001, 0b001],

        "A": [0b111, 0b101, 0b111, 0b101, 0b101],
        "B": [0b110, 0b101, 0b110, 0b101, 0b110],
        "C": [0b111, 0b100, 0b100, 0b100, 0b111],
        "D": [0b110, 0b101, 0b101, 0b101, 0b110],
        "E": [0b111, 0b100, 0b111, 0b100, 0b111],
        "F": [0b111, 0b100, 0b111, 0b100, 0b100],
        "G": [0b111, 0b100, 0b101, 0b101, 0b111],
        "H": [0b101, 0b101, 0b111, 0b101, 0b101],
        "I": [0b111, 0b010, 0b010, 0b010, 0b111],
        "J": [0b001, 0b001, 0b001, 0b101, 0b111],
        "K": [0b101, 0b101, 0b110, 0b101, 0b101],
        "L": [0b100, 0b100, 0b100, 0b100, 0b111],
        "M": [0b101, 0b111, 0b111, 0b101, 0b101],
        "N": [0b110, 0b101, 0b101, 0b101, 0b101],
        "O": [0b111, 0b101, 0b101, 0b101, 0b111],
        "P": [0b111, 0b101, 0b111, 0b100, 0b100],
        "Q": [0b111, 0b101, 0b101, 0b111, 0b001],
        "R": [0b111, 0b101, 0b110, 0b101, 0b101],
        "S": [0b111, 0b100, 0b111, 0b001, 0b111],
        "T": [0b111, 0b010, 0b010, 0b010, 0b010],
        "U": [0b101, 0b101, 0b101, 0b101, 0b111],
        "V": [0b101, 0b101, 0b101, 0b101, 0b010],
        "W": [0b101, 0b101, 0b111, 0b111, 0b101],
        "X": [0b101, 0b101, 0b010, 0b101, 0b101],
        "Y": [0b101, 0b101, 0b010, 0b010, 0b010],
        "Z": [0b111, 0b001, 0b010, 0b100, 0b111],

        "%": [0b101, 0b001, 0b010, 0b100, 0b101],
        ":": [0b000, 0b010, 0b000, 0b010, 0b000],
        "(": [0b010, 0b100, 0b100, 0b100, 0b010],
        ")": [0b010, 0b001, 0b001, 0b001, 0b010],
        "-": [0b000, 0b000, 0b111, 0b000, 0b000],
        "?": [0b111, 0b001, 0b010, 0b000, 0b010],
        " ": [0b000, 0b000, 0b000, 0b000, 0b000],
    ]

    /// Unknown characters render as "?" rather than silently vanishing, so a
    /// missing glyph is visible on the panel instead of becoming a mystery gap.
    static func glyph(for character: Character) -> [UInt8] {
        glyphs[character] ?? glyphs["?"]!
    }

    /// Pixel width of a string, excluding the trailing inter-character gap.
    static func width(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.count * advance - 1
    }
}
