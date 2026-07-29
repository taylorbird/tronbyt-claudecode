import Foundation

/// One rate limit as the display shows it: a two-letter label, a whole
/// percentage, and when it resets.
struct UsageLimit: Equatable {
    let label: String
    let percent: Int
    let resetsAt: Date?
}

/// A parsed snapshot of `GET /api/oauth/usage`.
///
/// Mirrors `limits_from()` in claude_usage.star: prefer the `limits` array, fall
/// back to `five_hour`/`seven_day`, and cap at three because only three gauges fit
/// on a 64x32 panel. Unknown top-level keys are ignored — the real payload carries
/// several we don't model and more appear over time.
struct UsageSnapshot: Equatable {
    let limits: [UsageLimit]

    /// The session (5-hour) percentage — the number shown in the menu bar.
    var sessionPercent: Int? {
        limits.first { $0.label == "5H" }?.percent
    }

    init(json: Data) throws {
        let root = try JSONSerialization.jsonObject(with: json)
        guard let object = root as? [String: Any] else {
            throw UsageSnapshotError.notAnObject
        }
        self.limits = Self.parseLimits(from: object)
    }

    init(limits: [UsageLimit]) {
        self.limits = limits
    }

    private static func parseLimits(from object: [String: Any]) -> [UsageLimit] {
        if let entries = object["limits"] as? [[String: Any]], !entries.isEmpty {
            return entries.compactMap(limit(from:)).prefix(3).map { $0 }
        }
        // Older/simpler shape: two top-level objects carrying `utilization`.
        let pairs: [(String, Any?)] = [("5H", object["five_hour"]), ("WK", object["seven_day"])]
        return pairs.compactMap { label, value in
            guard let dict = value as? [String: Any],
                  let utilization = dict["utilization"] as? Double else { return nil }
            return UsageLimit(label: label,
                              percent: Int(utilization),
                              resetsAt: date(from: dict["resets_at"]))
        }
    }

    private static func limit(from entry: [String: Any]) -> UsageLimit? {
        // A null percent means the limit exists but has no reading — skip it
        // rather than render a misleading zero.
        guard let percent = entry["percent"] as? Int else { return nil }
        return UsageLimit(label: label(for: entry),
                          percent: percent,
                          resetsAt: date(from: entry["resets_at"]))
    }

    private static func label(for entry: [String: Any]) -> String {
        switch entry["kind"] as? String {
        case "session": return "5H"
        case "weekly_all": return "WK"
        default:
            // Scoped limits are labelled by their model, e.g. Fable -> "FA".
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = model?["display_name"] as? String ?? "??"
            return String(name.prefix(2)).uppercased()
        }
    }

    /// The API sends RFC 3339 with fractional seconds, e.g.
    /// "2026-07-28T20:49:59.175242+00:00". `.iso8601` alone rejects that, so try
    /// the fractional variant first.
    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

enum UsageSnapshotError: Error, CustomStringConvertible {
    case notAnObject

    var description: String {
        switch self {
        case .notAnObject: return "usage response was not a JSON object"
        }
    }
}
