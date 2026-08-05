import Testing
@testable import Yana

@MainActor
struct WindowIdentityTests {
    // The `FeedEditorTarget` round-trip/identity tests are gone with the type: the feed editor is no
    // longer a window (edit pushes in the Settings window, create is a sheet), so there is no
    // `WindowGroup(for:)` value left to keep `Codable`/`Hashable`.

    @Test func settingsPanesAreStableAndOrdered() {
        #expect(SettingsPane.allCases == [.general, .reader, .manage, .ai, .about, .diagnostics])
        #expect(SettingsPane.ai.rawValue == "ai")
    }
}
