import AppKit

/// The menu bar glyph: Clawd, Claude Code's pixel critter, drawn from a
/// paint-by-rows map. Hand-approximated in code — no bundled or extracted
/// artwork.
enum MenuBarIcon {

    /// 'X' = body pixel, '.' = transparent. The eyes and the leg gaps are
    /// punched out, so whatever is behind the menu bar shows through them.
    static let pixelRows: [String] = [
        "...XXXXXXXXX...",
        "..XXXXXXXXXXX..",
        ".XXXXXXXXXXXXX.",
        ".XXXXXXXXXXXXX.",
        ".XXX..XXX..XXX.",
        ".XXX..XXX..XXX.",
        ".XXXXXXXXXXXXX.",
        ".XXXXXXXXXXXXX.",
        ".XXXXXXXXXXXXX.",
        ".XXXXXXXXXXXXX.",
        "..XX..XXX..XX..",
        "..XX..XXX..XX..",
    ]

    /// One point per pixel: 15x12. Integral cells keep the art crisp — scaling
    /// to a non-integral cell size blurs it on every display.
    static let pointSize = NSSize(width: 15, height: 12)

    /// Claude's brand orange. Deliberately NOT a template image: the system
    /// recoloring a template to black/white would erase exactly what makes the
    /// character recognizable.
    static let bodyColor = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0,
                                   blue: 0x57 / 255.0, alpha: 1)

    static let image: NSImage = {
        let image = clawd(cellSize: 1)
        image.isTemplate = false
        return image
    }()

    /// Clawd at any scale — the About screen shows the same critter, bigger.
    /// flipped: true so row 0 of the map is the TOP of the icon.
    static func clawd(cellSize: CGFloat) -> NSImage {
        let size = NSSize(width: pointSize.width * cellSize,
                          height: pointSize.height * cellSize)
        return NSImage(size: size, flipped: true) { _ in
            bodyColor.setFill()
            for (y, row) in pixelRows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "X" {
                    NSRect(x: CGFloat(x) * cellSize, y: CGFloat(y) * cellSize,
                           width: cellSize, height: cellSize).fill()
                }
            }
            return true
        }
    }
}
