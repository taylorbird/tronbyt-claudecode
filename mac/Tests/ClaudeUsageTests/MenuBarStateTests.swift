import XCTest
@testable import ClaudeUsage

final class MenuBarStateTests: XCTestCase {

    func testFreshShowsThePercent() {
        let state = MenuBarState.make(sessionPercent: 48, staleness: .fresh,
                                      credentialProblem: false)
        XCTAssertEqual(state.text, "5H 48%")
        XCTAssertFalse(state.showsWarning)
    }

    func testDeadShowsPlaceholderEvenWhenOldDataExists() {
        let state = MenuBarState.make(sessionPercent: 48, staleness: .dead,
                                      credentialProblem: false)
        XCTAssertEqual(state.text, "5H --")
    }

    func testNoDataShowsPlaceholder() {
        let state = MenuBarState.make(sessionPercent: nil, staleness: .warning,
                                      credentialProblem: false)
        XCTAssertEqual(state.text, "5H --")
    }

    /// The logged-out case this exists for: the warning must be visible in the
    /// menu bar itself, not only inside the opened menu.
    func testCredentialProblemRaisesTheWarning() {
        let state = MenuBarState.make(sessionPercent: nil, staleness: .dead,
                                      credentialProblem: true)
        XCTAssertEqual(state.text, "5H --")
        XCTAssertTrue(state.showsWarning)
    }

    /// A credential problem with still-fresh numbers (token just revoked) keeps
    /// the numbers AND warns — the two are independent signals.
    func testWarningCoexistsWithFreshNumbers() {
        let state = MenuBarState.make(sessionPercent: 48, staleness: .fresh,
                                      credentialProblem: true)
        XCTAssertEqual(state.text, "5H 48%")
        XCTAssertTrue(state.showsWarning)
    }
}
