import Testing

@Suite("Yana Tests")
struct YanaTests {
    @Test func appStateDefaults() {
        let state = AppState()
        #expect(state.isAuthenticated == false)
        #expect(state.serverURL == nil)
        #expect(state.authToken == nil)
    }
}
