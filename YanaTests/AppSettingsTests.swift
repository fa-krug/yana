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

    @Test func hasSkippedServerPairingDefaultsToFalseAndRoundTrips() {
        let settings = freshSettings()
        #expect(settings.hasSkippedServerPairing == false)
        settings.hasSkippedServerPairing = true
        #expect(settings.hasSkippedServerPairing == true)
    }

    @Test func hasDismissedDemoBannerDefaultsToFalseAndRoundTrips() {
        let settings = freshSettings()
        #expect(settings.hasDismissedDemoBanner == false)
        settings.hasDismissedDemoBanner = true
        #expect(settings.hasDismissedDemoBanner == true)
    }
}
