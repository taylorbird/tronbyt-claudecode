import Foundation

/// How old the data is, and therefore how the frame should present it.
///
/// The rule this exists to enforce: never show a stale number as though it were
/// current. That is the bug that started this whole rewrite — the previous
/// companion served its last good body with HTTP 200 while its own fetches were
/// failing, and the display had no way to tell fresh from frozen.
enum Staleness {

    enum Tier: Equatable {
        /// Normal, full colour.
        case fresh
        /// Recent failure: keep the colours, add a warning border.
        case warning
        /// Old enough that the numbers are fiction: render everything grey.
        case dead
    }

    /// A few minutes behind does not matter — these numbers move slowly.
    static let warningAfter: TimeInterval = 6 * 60
    /// Past an hour, something is genuinely wrong or the Mac was asleep.
    static let deadAfter: TimeInterval = 60 * 60

    static func tier(ageSeconds: TimeInterval) -> Tier {
        // Clock skew between the fetch timestamp and now can make age negative;
        // that is not staleness.
        if ageSeconds < warningAfter { return .fresh }
        if ageSeconds < deadAfter { return .warning }
        return .dead
    }

    static func tier(fetchedAt: Date?, now: Date = Date()) -> Tier {
        // Never fetched at all is the worst case, not the freshest.
        guard let fetchedAt else { return .dead }
        return tier(ageSeconds: now.timeIntervalSince(fetchedAt))
    }

    /// "AS OF 11:42" — answers "how old is this" without the reader doing
    /// arithmetic, and stays correct however long the app was away.
    static func asOfText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        // en_US_POSIX pins the calendar and numbering system: a fixed dateFormat
        // still follows the user's locale otherwise, so a non-Latin numbering
        // system would emit digits the 6px font cannot render.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return "AS OF \(formatter.string(from: date))"
    }
}
