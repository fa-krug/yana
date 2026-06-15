import Testing
@testable import Yana

@MainActor
@Suite("Yana Tests")
struct YanaTests {
    @Test func appStateDefaults() {
        let state = AppState()
        #expect(state.currentIndex == 0)
        #expect(state.isUpdating == false)
        #expect(state.showSettings == false)
        #expect(state.showFilter == false)
    }
}
