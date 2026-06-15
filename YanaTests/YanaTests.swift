import Testing
@testable import Yana

@MainActor
@Suite("Yana Tests")
struct YanaTests {
    @Test func appStateDefaults() {
        let state = AppState()
        #expect(state.scope == .allUnread)
        #expect(state.currentIndex == 0)
        #expect(state.isUpdating == false)
        #expect(state.showSettings == false)
    }
}
