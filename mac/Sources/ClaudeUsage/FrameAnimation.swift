import Foundation

/// Assembles the frames the panel actually shows and encodes them.
///
/// Two frames alternating the reset row, because `5H 13:49(1H20M)` and its weekly
/// equivalent will not fit across 64px at the same time.
enum FrameAnimation {

    /// Matches the `delay` in claude_usage.star.
    static let frameDurationMs = 2500

    /// Encoded animated WebP, ready to push.
    static func encode(snapshot: UsageSnapshot,
                       tier: Staleness.Tier,
                       fetchedAt: Date?,
                       now: Date = Date()) throws -> Data {
        try WebPAnimation.encode(frames: frames(snapshot: snapshot, tier: tier,
                                                fetchedAt: fetchedAt, now: now),
                                 width: FrameRenderer.width,
                                 height: FrameRenderer.height,
                                 frameDurationMs: frameDurationMs)
    }

    /// The raw RGBA frames. One frame when both variants would look identical —
    /// animating between two identical frames just wastes bytes and makes the
    /// display flicker for no reason.
    static func frames(snapshot: UsageSnapshot,
                       tier: Staleness.Tier,
                       fetchedAt: Date?,
                       now: Date = Date()) -> [[UInt8]] {
        let session = FrameRenderer.render(snapshot: snapshot, tier: tier,
                                           fetchedAt: fetchedAt, resetRow: .session, now: now)
        let weekly = FrameRenderer.render(snapshot: snapshot, tier: tier,
                                          fetchedAt: fetchedAt, resetRow: .weekly, now: now)
        return session == weekly ? [session] : [session, weekly]
    }
}
