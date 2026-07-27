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
}
