import Foundation

/// What the menu bar item displays. Pure so it is testable — the SwiftUI label
/// just renders this.
struct MenuBarState: Equatable {
    /// Text shown in the menu bar.
    let text: String
    /// Render a warning symbol before the text. Only credential problems raise
    /// this: it means "the fix is logging into Claude Code", not "a fetch
    /// hiccuped". Transient failures already surface via staleness.
    let showsWarning: Bool

    /// Always the 5-hour figure — it moves fastest and gates the next hour of
    /// work, and a number whose meaning never changes can be read at a glance.
    static func make(sessionPercent: Int?,
                     staleness: Staleness.Tier,
                     credentialProblem: Bool) -> MenuBarState {
        let text: String
        if staleness == .dead || sessionPercent == nil {
            text = "5H --"
        } else {
            text = "5H \(sessionPercent!)%"
        }
        return MenuBarState(text: text, showsWarning: credentialProblem)
    }
}
