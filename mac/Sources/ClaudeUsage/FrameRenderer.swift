import Foundation

/// Draws the 64x32 frame. Layout and colours follow claude_usage.star so the native
/// renderer produces what pixlet has been producing.
enum FrameRenderer {

    static let width = 64
    static let height = 32
    /// Top row reserved for the reset countdown.
    static let resetRowHeight = 6
    /// Red screen border once the session or weekly limit reaches this.
    static let alertPercent = 90

    /// Which limit's reset time the top row is showing. The row alternates because
    /// both countdowns will not fit across 64px at once.
    enum ResetRow {
        case session
        case weekly
    }

    static func colour(forPercent percent: Int) -> RGBA {
        if percent >= 80 { return Palette.red }
        if percent >= 50 { return Palette.amber }
        return Palette.green
    }

    /// "1H30M" under a day, "2D" beyond it. Negative durations clamp to zero rather
    /// than rendering a minus sign that would not fit.
    static func countdownText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        if totalMinutes >= 24 * 60 {
            return "\(totalMinutes / (24 * 60))D"
        }
        let minutes = totalMinutes % 60
        return "\(totalMinutes / 60)H\(minutes < 10 ? "0" : "")\(minutes)M"
    }

    /// Render one frame.
    ///
    /// When `tier` is `.dead` everything is drawn in grey and the reset row is
    /// replaced with `AS OF <time>`: the numbers stay visible but are unmistakably
    /// not current. That is the whole point — a red error screen hides information,
    /// and showing live colours would be a lie.
    static func render(snapshot: UsageSnapshot,
                       tier: Staleness.Tier,
                       fetchedAt: Date?,
                       resetRow: ResetRow,
                       now: Date = Date()) -> [UInt8] {
        var canvas = Canvas(width: width, height: height)
        let limits = snapshot.limits
        let isDead = tier == .dead

        drawTopRow(&canvas, limits: limits, resetRow: resetRow,
                   isDead: isDead, fetchedAt: fetchedAt, now: now)

        if limits.count > 2 {
            drawThreeGauges(&canvas, limits: limits, isDead: isDead)
        } else if !limits.isEmpty {
            drawTwoGauges(&canvas, limits: limits, isDead: isDead)
        }

        drawBorder(&canvas, limits: limits, tier: tier)
        return canvas.pixels
    }

    private static func drawTopRow(_ canvas: inout Canvas, limits: [UsageLimit],
                                   resetRow: ResetRow, isDead: Bool,
                                   fetchedAt: Date?, now: Date) {
        if isDead {
            let text = fetchedAt.map { Staleness.asOfText($0) } ?? "NO DATA"
            canvas.draw(text: text, x: 0, y: 0, colour: Palette.grey)
            return
        }
        // Fall back to the other limit when the requested one is absent, so a
        // snapshot with only a session limit renders a stable static row rather
        // than alternating between a populated row and an empty one.
        let preferred = resetRow == .session ? "5H" : "WK"
        let fallback = resetRow == .session ? "WK" : "5H"
        let candidates = [preferred, fallback].compactMap { label in
            limits.first { $0.label == label && $0.resetsAt != nil }
        }
        guard let limit = candidates.first, let resetsAt = limit.resetsAt else { return }

        // Matches reset_frames() in claude_usage.star:
        //   "5H 13:49(1H20M)"        under a day
        //   "WK MON 17:00(4D)"       a day or more out, weekday highlighted
        // tom-thumb has no bold, so emphasis is white label against grey detail.
        var x = 0
        canvas.draw(text: limit.label, x: x, y: 0, colour: Palette.white)
        x += PixelFont.advance * (limit.label.count + 1)

        let secondsUntil = resetsAt.timeIntervalSince(now)
        if secondsUntil >= 24 * 3600 {
            let weekday = Self.weekdayText(resetsAt)
            canvas.draw(text: weekday, x: x, y: 0, colour: Palette.day)
            x += PixelFont.advance * (weekday.count + 1)
        }

        let detail = "\(Self.clockText(resetsAt))(\(countdownText(secondsUntil)))"
        canvas.draw(text: detail, x: x, y: 0, colour: Palette.label)
    }

    /// Local wall-clock time the limit resets, e.g. "13:49".
    static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Three-letter weekday, e.g. "MON". Shown only when the reset is a day or more
    /// away, since a bare clock time would be ambiguous by then.
    static func weekdayText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        formatter.timeZone = timeZone
        return formatter.string(from: date).uppercased()
    }

    /// Three limits: 20px rings, bare number inside, label beneath.
    private static func drawThreeGauges(_ canvas: inout Canvas, limits: [UsageLimit],
                                       isDead: Bool) {
        let diameter = 20
        let slot = width / 3
        for (index, limit) in limits.prefix(3).enumerated() {
            let originX = index * slot + (slot - diameter) / 2
            let originY = resetRowHeight
            let fill = isDead ? Palette.grey : colour(forPercent: limit.percent)
            let track = isDead ? Palette.black : Palette.track
            canvas.drawRing(centreX: originX, centreY: originY, diameter: diameter,
                            fraction: Double(min(max(limit.percent, 0), 100)) / 100.0,
                            fill: fill, track: track)
            let number = "\(limit.percent)"
            canvas.draw(text: number,
                        x: originX + (diameter - PixelFont.width(of: number)) / 2,
                        y: originY + (diameter - PixelFont.glyphHeight) / 2,
                        colour: fill)
            canvas.draw(text: limit.label,
                        x: originX + (diameter - PixelFont.width(of: limit.label)) / 2,
                        y: originY + diameter,
                        colour: isDead ? Palette.grey : Palette.label)
        }
    }

    /// One or two limits: 26px rings with the label and percentage stacked inside.
    private static func drawTwoGauges(_ canvas: inout Canvas, limits: [UsageLimit],
                                     isDead: Bool) {
        let diameter = 26
        let slot = width / max(limits.count, 1)
        for (index, limit) in limits.enumerated() {
            let originX = index * slot + (slot - diameter) / 2
            let originY = resetRowHeight
            let fill = isDead ? Palette.grey : colour(forPercent: limit.percent)
            let track = isDead ? Palette.black : Palette.track
            canvas.drawRing(centreX: originX, centreY: originY, diameter: diameter,
                            fraction: Double(min(max(limit.percent, 0), 100)) / 100.0,
                            fill: fill, track: track)
            canvas.draw(text: limit.label,
                        x: originX + (diameter - PixelFont.width(of: limit.label)) / 2,
                        y: originY + 7,
                        colour: isDead ? Palette.grey : Palette.label)
            let percent = "\(limit.percent)%"
            canvas.draw(text: percent,
                        x: originX + (diameter - PixelFont.width(of: percent)) / 2,
                        y: originY + 14,
                        colour: fill)
        }
    }

    /// Red border at 90%+ on a real limit; amber when merely falling behind. Red
    /// outranks amber — a genuine 90% reading is the more urgent of the two, and
    /// only one border fits. A dead frame gets no border at all: it is already
    /// entirely grey, and a coloured border would reintroduce the live signal the
    /// grey exists to remove.
    private static func drawBorder(_ canvas: inout Canvas, limits: [UsageLimit],
                                  tier: Staleness.Tier) {
        let alerting = limits.contains {
            ($0.label == "5H" || $0.label == "WK") && $0.percent >= alertPercent
        }
        let colour: RGBA
        switch (alerting, tier) {
        case (true, .fresh), (true, .warning): colour = Palette.red
        case (false, .warning):                colour = Palette.amber
        default:                               return
        }
        for x in 0..<width {
            canvas.set(x: x, y: 0, to: colour)
            canvas.set(x: x, y: height - 1, to: colour)
        }
        for y in 0..<height {
            canvas.set(x: 0, y: y, to: colour)
            canvas.set(x: width - 1, y: y, to: colour)
        }
    }
}
