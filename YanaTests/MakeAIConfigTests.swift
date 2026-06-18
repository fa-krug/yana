import Foundation
import Testing
@testable import Yana

@MainActor
struct MakeAIConfigTests {
    private func settings(provider: AIProvider) -> AppSettings {
        let defaults = UserDefaults(suiteName: "test.makeaiconfig.\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        s.activeAIProvider = provider
        return s
    }

    @Test func mistralResolvesModelKeyAndBaseURL() {
        let s = settings(provider: .mistral)
        s.mistralModel = "mistral-large-latest"
        let cfg = AggregationService.makeAIConfig(settings: s) { item in
            item == .mistralAPIKey ? "MK" : nil
        }
        #expect(cfg.provider == .mistral)
        #expect(cfg.model == "mistral-large-latest")
        #expect(cfg.apiKey == "MK")
        #expect(cfg.apiBaseURL == "https://api.mistral.ai/v1")
    }

    @Test func qwenAndDeepseekResolveBaseURLs() {
        let q = AggregationService.makeAIConfig(settings: settings(provider: .qwen)) { _ in "K" }
        #expect(q.apiBaseURL == AIProvider.qwen.baseURL)
        let d = AggregationService.makeAIConfig(settings: settings(provider: .deepseek)) { _ in "K" }
        #expect(d.apiBaseURL == AIProvider.deepseek.baseURL)
    }

    @Test func openaiStillUsesUserOverridableURL() {
        let s = settings(provider: .openai)
        s.openaiAPIURL = "https://proxy.example.com/v1"
        let cfg = AggregationService.makeAIConfig(settings: s) { _ in "K" }
        #expect(cfg.apiBaseURL == "https://proxy.example.com/v1")
    }
}
