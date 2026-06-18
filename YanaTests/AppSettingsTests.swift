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

    @Test func aiKnobsHaveServerParityDefaults() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.aiTemperature == 0.3)
        #expect(s.aiMaxTokens == 2000)
        #expect(s.aiRequestDelay == 2)
        #expect(s.redditUserAgent == "Yana/1.0")
        #expect(s.openaiAPIURL == "https://api.openai.com/v1")
        #expect(s.openaiModel == "gpt-4o-mini")
    }

    @Test func providerModelListsAreNonEmpty() {
        #expect(AIProvider.openai.models.contains("gpt-4o-mini"))
        #expect(!AIProvider.anthropic.models.isEmpty)
        #expect(!AIProvider.gemini.models.isEmpty)
        #expect(AIProvider.none.models.isEmpty)
    }

    @Test func newFieldsPersist() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        s.aiTemperature = 0.7
        s.anthropicModel = "claude-sonnet-4-6"
        s.redditEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiTemperature == 0.7)
        #expect(reloaded.anthropicModel == "claude-sonnet-4-6")
        #expect(reloaded.redditEnabled == true)
    }

    @Test func notificationsDisabledByDefault() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.notificationsEnabled == false)
    }

    @Test func notificationsEnabledPersists() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        s.notificationsEnabled = true
        #expect(AppSettings(defaults: defaults).notificationsEnabled == true)
    }

    @Test func activeAIProviderChangeIsObserved() {
        let s = AppSettings(defaults: freshDefaults())
        nonisolated(unsafe) var fired = false
        withObservationTracking {
            _ = s.activeAIProvider
        } onChange: {
            fired = true
        }
        s.activeAIProvider = .anthropic
        #expect(fired)
    }

    @Test func changingTextSizePostsChangeNotification() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.articleTextSize = .medium // baseline

        nonisolated(unsafe) var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: AppSettings.articleTextSizeDidChange, object: nil, queue: nil
        ) { _ in posted = true }

        settings.articleTextSize = .large
        NotificationCenter.default.removeObserver(token)
        #expect(posted)
    }

    @Test func settingSameTextSizeDoesNotPost() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.articleTextSize = .large

        nonisolated(unsafe) var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: AppSettings.articleTextSizeDidChange, object: nil, queue: nil
        ) { _ in posted = true }

        settings.articleTextSize = .large // unchanged
        NotificationCenter.default.removeObserver(token)
        #expect(!posted)
    }

    @Test func isSourceEnabledGatesRedditAndYouTube() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)

        // Off by default.
        #expect(settings.isSourceEnabled(.reddit) == false)
        #expect(settings.isSourceEnabled(.youtube) == false)
        // Non-gated types are always active.
        #expect(settings.isSourceEnabled(.feedContent) == true)
        #expect(settings.isSourceEnabled(.heise) == true)

        settings.redditEnabled = true
        settings.youtubeEnabled = true
        #expect(settings.isSourceEnabled(.reddit) == true)
        #expect(settings.isSourceEnabled(.youtube) == true)
    }
}
