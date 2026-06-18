import Foundation
import Testing
@testable import Yana

/// Hermetic tests for `AggregationService.makeAIConfig` — the settings -> engine bridge.
/// Uses an isolated `UserDefaults` suite and an injected key loader, so neither
/// `UserDefaults.standard` nor the real Keychain is ever touched.
@MainActor
@Suite("AggregationService.makeAIConfig")
struct AggregationAIConfigTests {
    /// A fresh `AppSettings` backed by a throwaway, empty `UserDefaults` suite.
    private func makeSettings(_ suite: String) -> AppSettings {
        let name = "test.makeAIConfig.\(suite)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppSettings(defaults: defaults)
    }

    /// Key loader that returns a canned value for any item, recording the items asked for.
    private final class FakeKeyStore {
        var requested: [KeychainService.APIKeyItem] = []
        let value: String?
        init(returning value: String?) { self.value = value }
        func load(_ item: KeychainService.APIKeyItem) -> String? {
            requested.append(item)
            return value
        }
    }

    @Test func noneProviderYieldsEmptyModelAndKeyWithoutTouchingKeychain() {
        let settings = makeSettings("none")
        settings.activeAIProvider = .none
        let store = FakeKeyStore(returning: "should-not-be-used")

        let config = AggregationService.makeAIConfig(settings: settings, loadKey: store.load)

        #expect(config.provider == .none)
        #expect(config.model == "")
        #expect(config.apiKey == "")
        #expect(store.requested.isEmpty)   // .none never consults the key store
    }

    @Test func openaiSelectsOpenAIModelAndKey() {
        let settings = makeSettings("openai")
        settings.activeAIProvider = .openai
        settings.openaiModel = "gpt-4o"
        let store = FakeKeyStore(returning: "sk-openai")

        let config = AggregationService.makeAIConfig(settings: settings, loadKey: store.load)

        #expect(config.provider == .openai)
        #expect(config.model == "gpt-4o")
        #expect(config.apiKey == "sk-openai")
        #expect(store.requested == [.openaiAPIKey])
    }

    @Test func anthropicSelectsAnthropicModelAndKey() {
        let settings = makeSettings("anthropic")
        settings.activeAIProvider = .anthropic
        settings.anthropicModel = "claude-opus-4-8"
        let store = FakeKeyStore(returning: "sk-ant")

        let config = AggregationService.makeAIConfig(settings: settings, loadKey: store.load)

        #expect(config.provider == .anthropic)
        #expect(config.model == "claude-opus-4-8")
        #expect(config.apiKey == "sk-ant")
        #expect(store.requested == [.anthropicAPIKey])
    }

    @Test func geminiSelectsGeminiModelAndKey() {
        let settings = makeSettings("gemini")
        settings.activeAIProvider = .gemini
        settings.geminiModel = "gemini-2.5-pro"
        let store = FakeKeyStore(returning: "g-key")

        let config = AggregationService.makeAIConfig(settings: settings, loadKey: store.load)

        #expect(config.provider == .gemini)
        #expect(config.model == "gemini-2.5-pro")
        #expect(config.apiKey == "g-key")
        #expect(store.requested == [.geminiAPIKey])
    }

    @Test func missingKeyResolvesToEmptyString() {
        let settings = makeSettings("missingkey")
        settings.activeAIProvider = .openai
        let store = FakeKeyStore(returning: nil)   // no key stored

        let config = AggregationService.makeAIConfig(settings: settings, loadKey: store.load)

        #expect(config.apiKey == "")
        #expect(store.requested == [.openaiAPIKey])
    }

    @Test func nonProviderFieldsMapFromSettingsAndMaxRetryTimeIsFixed() {
        let settings = makeSettings("fields")
        settings.activeAIProvider = .openai
        settings.openaiAPIURL = "https://proxy.example/v1"
        settings.aiTemperature = 0.7
        settings.aiMaxTokens = 1234
        settings.aiRequestTimeout = 45
        settings.aiMaxRetries = 5
        settings.aiRetryDelay = 9

        let config = AggregationService.makeAIConfig(settings: settings, loadKey: { _ in "k" })

        #expect(config.apiBaseURL == "https://proxy.example/v1")
        #expect(config.temperature == 0.7)
        #expect(config.maxTokens == 1234)
        #expect(config.requestTimeout == 45)
        #expect(config.maxRetries == 5)
        #expect(config.retryDelay == 9)
        #expect(config.maxRetryTime == 60)   // fixed at the server default (no AppSettings property)
    }
}
