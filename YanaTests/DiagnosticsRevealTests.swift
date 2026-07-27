import Foundation
import Testing
@testable import Yana

struct DiagnosticsRevealTests {

    @Test func firstTapStartsTheWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let result = DiagnosticsReveal.register(DiagnosticsReveal.State(), at: now)
        #expect(result.state.count == 1)
        #expect(result.state.firstTapAt == now)
        #expect(result.unlocked == false)
    }

    @Test func fiveTapsInsideTheWindowUnlock() {
        var state = DiagnosticsReveal.State()
        var unlocked = false
        for step in 0..<5 {
            let result = DiagnosticsReveal.register(
                state, at: Date(timeIntervalSince1970: 1000 + Double(step) * 0.4)
            )
            state = result.state
            unlocked = result.unlocked
        }
        #expect(unlocked)
        #expect(state.count == 5)
    }

    @Test func fourTapsDoNotUnlock() {
        var state = DiagnosticsReveal.State()
        var unlocked = false
        for step in 0..<4 {
            let result = DiagnosticsReveal.register(
                state, at: Date(timeIntervalSince1970: 1000 + Double(step) * 0.4)
            )
            state = result.state
            unlocked = result.unlocked
        }
        #expect(unlocked == false)
    }

    @Test func aTapAfterTheWindowRestartsCounting() {
        var state = DiagnosticsReveal.State()
        for step in 0..<3 {
            state = DiagnosticsReveal.register(
                state, at: Date(timeIntervalSince1970: 1000 + Double(step) * 0.4)
            ).state
        }
        #expect(state.count == 3)

        // 10s later — outside the 3s window.
        let result = DiagnosticsReveal.register(state, at: Date(timeIntervalSince1970: 1010))
        #expect(result.state.count == 1)
        #expect(result.unlocked == false)
    }

    @Test func aTapExactlyAtTheWindowBoundaryStillCounts() {
        let firstTapAt = Date(timeIntervalSince1970: 1000)
        let state = DiagnosticsReveal.State(firstTapAt: firstTapAt, count: 1)

        // Exactly `window` (3.0s) after the first tap — the boundary is inclusive.
        let result = DiagnosticsReveal.register(state, at: firstTapAt.addingTimeInterval(3.0))
        #expect(result.state.firstTapAt == firstTapAt)
        #expect(result.state.count == 2)
        #expect(result.unlocked == false)
    }

    // MARK: - Visibility

    // The property the whole reveal gesture exists to guarantee: Diagnostics is *hidden* until it is
    // unlocked. Both settings hosts embed this rule, one of them inside a Catalyst-only view, so
    // asserting it here is the only place it is checked.

    @Test func diagnosticsIsHiddenWhileLockedAndUnrevealed() {
        #expect(DiagnosticsReveal.isDiagnosticsVisible(unlocked: false, revealed: false) == false)
        #expect(DiagnosticsReveal.visiblePanes(unlocked: false, revealed: false).contains(.diagnostics) == false)
    }

    @Test func diagnosticsIsVisibleOnceThePreferenceIsUnlocked() {
        #expect(DiagnosticsReveal.isDiagnosticsVisible(unlocked: true, revealed: false))
        #expect(DiagnosticsReveal.visiblePanes(unlocked: true, revealed: false).contains(.diagnostics))
    }

    /// The five-tap gesture flips `diagnosticsUnlocked` on the *About section's* own `AppSettings`
    /// instance, which the enclosing settings screen is not guaranteed to observe — so the reveal
    /// must also take effect from the host's own `revealed` state alone.
    @Test func diagnosticsIsVisibleWhenRevealedBeforeThePreferenceIsRead() {
        #expect(DiagnosticsReveal.isDiagnosticsVisible(unlocked: false, revealed: true))
        #expect(DiagnosticsReveal.visiblePanes(unlocked: false, revealed: true).contains(.diagnostics))
    }

    @Test func hidingDiagnosticsRemovesOnlyThatPaneAndKeepsTheOrder() {
        let hidden = DiagnosticsReveal.visiblePanes(unlocked: false, revealed: false)
        #expect(hidden == SettingsPane.allCases.filter { $0 != .diagnostics })

        let shown = DiagnosticsReveal.visiblePanes(unlocked: true, revealed: false)
        #expect(shown == SettingsPane.allCases)
    }

    @Test func aTapJustPastTheWindowBoundaryResets() {
        let firstTapAt = Date(timeIntervalSince1970: 1000)
        let state = DiagnosticsReveal.State(firstTapAt: firstTapAt, count: 1)

        // Just past `window` — the same tap count now restarts instead of continuing.
        let now = firstTapAt.addingTimeInterval(3.001)
        let result = DiagnosticsReveal.register(state, at: now)
        #expect(result.state.firstTapAt == now)
        #expect(result.state.count == 1)
        #expect(result.unlocked == false)
    }
}
