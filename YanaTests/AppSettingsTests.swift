import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    @Test func hasSaneDefaults() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.activeAIProvider == .none)
        #expect(settings.retentionDays == 30)
        #expect(settings.backgroundInterval == 1800)
    }

    @Test func persistsChanges() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.retentionDays = 7
        settings.activeAIProvider = .anthropic

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.retentionDays == 7)
        #expect(reloaded.activeAIProvider == .anthropic)
    }

    @Test func keychainAPIKeyRoundTrip() {
        KeychainService.saveAPIKey("secret-123", for: .youtubeAPIKey)
        #expect(KeychainService.loadAPIKey(for: .youtubeAPIKey) == "secret-123")
        KeychainService.deleteAPIKey(for: .youtubeAPIKey)
        #expect(KeychainService.loadAPIKey(for: .youtubeAPIKey) == nil)
    }
}
