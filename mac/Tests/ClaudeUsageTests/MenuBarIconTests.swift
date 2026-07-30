import AppKit
import XCTest
@testable import ClaudeUsage

final class MenuBarIconTests: XCTestCase {

    /// A ragged row would silently shift pixels; the size must match the map
    /// exactly because the art is drawn at one point per pixel.
    func testPixelMapIsRectangularAndMatchesTheImageSize() {
        let widths = Set(MenuBarIcon.pixelRows.map(\.count))
        XCTAssertEqual(widths.count, 1, "all rows must be the same width")
        XCTAssertEqual(MenuBarIcon.pointSize.width, CGFloat(widths.first!))
        XCTAssertEqual(MenuBarIcon.pointSize.height, CGFloat(MenuBarIcon.pixelRows.count))
    }

    /// Deliberately NOT a template: the system recoloring it would erase the
    /// character's orange, which is the point of using the character.
    func testIconKeepsItsOwnColor() {
        XCTAssertFalse(MenuBarIcon.image.isTemplate)
    }

    /// Guards against the drawing closure silently producing a blank image.
    func testIconActuallyDrawsInk() {
        guard let tiff = MenuBarIcon.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return XCTFail("icon could not be rasterised")
        }
        var inked = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                    inked += 1
                }
            }
        }
        let bodyPixels = MenuBarIcon.pixelRows.joined().filter { $0 == "X" }.count
        XCTAssertGreaterThanOrEqual(inked, bodyPixels,
                                    "every body pixel should leave ink")
    }
}
