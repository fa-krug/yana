import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {
    private func freshSettings() -> AppSettings {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    @Test func showUnreadBadgeDefaultsToFalse() {
        #expect(freshSettings().showUnreadBadge == false)
    }

    @Test func showUnreadBadgeRoundTrips() {
        let settings = freshSettings()
        settings.showUnreadBadge = true
        #expect(settings.showUnreadBadge == true)
    }
}
