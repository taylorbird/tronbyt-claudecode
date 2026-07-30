#!/usr/bin/env swift
// Generates mac/Sources/ClaudeUsage/AppIcon.icns: Clawd on a dark rounded
// rectangle, following the macOS icon grid (the rounded square fills 824/1024
// of the canvas). Run from the repo root:
//
//   swift mac/tools/make-app-icon.swift
//
// The pixel map here mirrors MenuBarIcon.pixelRows — a script cannot import
// the app module, so keep the two in sync by hand.
import AppKit

let pixelRows = [
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
let clawdOrange = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0,
                          blue: 0x57 / 255.0, alpha: 1)
let terminalDark = NSColor(srgbRed: 0x26 / 255.0, green: 0x20 / 255.0,
                           blue: 0x1D / 255.0, alpha: 1)

func render(canvas: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas,
                               pixelsHigh: canvas, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(canvas) * 824.0 / 1024.0
    let origin = (CGFloat(canvas) - side) / 2
    let square = NSRect(x: origin, y: origin, width: side, height: side)
    terminalDark.setFill()
    NSBezierPath(roundedRect: square, xRadius: side * 0.225,
                 yRadius: side * 0.225).fill()

    let columns = CGFloat(pixelRows[0].count)
    let rows = CGFloat(pixelRows.count)
    // Integer cell + integer origin keeps every cell edge on a whole pixel —
    // fractional origins antialias each edge into visible seams between cells.
    // Below 1px/cell (the 16pt icon) fractional is unavoidable; it is 16px.
    let rawCell = side * 0.70 / columns
    let cell = rawCell >= 1 ? rawCell.rounded(.down) : rawCell
    let artWidth = cell * columns
    let artHeight = cell * rows
    let artX = ((CGFloat(canvas) - artWidth) / 2).rounded(.down)
    let artY = ((CGFloat(canvas) - artHeight) / 2).rounded(.down)

    clawdOrange.setFill()
    for (y, row) in pixelRows.enumerated() {
        // Bitmap y runs upward; row 0 of the map is the top.
        let flippedY = pixelRows.count - 1 - y
        for (x, c) in row.enumerated() where c == "X" {
            NSRect(x: artX + CGFloat(x) * cell, y: artY + CGFloat(flippedY) * cell,
                   width: cell, height: cell).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let repoRoot = FileManager.default.currentDirectoryPath
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset,
                                        withIntermediateDirectories: true)

// (filename points, scale) pairs iconutil requires.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                              (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let rep = render(canvas: points * scale)
    let suffix = scale == 2 ? "@2x" : ""
    let path = "\(iconset)/icon_\(points)x\(points)\(suffix).png"
    try rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let output = repoRoot + "/mac/Sources/ClaudeUsage/AppIcon.icns"
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", output]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(task.terminationStatus)")
}
print("wrote \(output)")
