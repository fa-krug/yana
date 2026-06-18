import Testing
@testable import Yana

@MainActor
struct AIProviderTests {
    @Test func appleIntelligenceHasNoModelsAndBrandName() {
        #expect(AIProvider.appleIntelligence.models.isEmpty)
        #expect(AIProvider.appleIntelligence.displayName == "Apple Intelligence")
        #expect(AIProvider.allCases.contains(.appleIntelligence))
    }

    @Test func newProvidersAreSelectable() {
        let all = AIProvider.allCases
        #expect(all.contains(.mistral))
        #expect(all.contains(.qwen))
        #expect(all.contains(.deepseek))
    }

    @Test func newProvidersHaveModelsAndDefault() {
        for p in [AIProvider.mistral, .qwen, .deepseek] {
            #expect(!p.models.isEmpty)
            #expect(p.defaultModel == p.models.first)
        }
    }

    @Test func baseURLsAreProviderSpecific() {
        #expect(AIProvider.mistral.baseURL == "https://api.mistral.ai/v1")
        #expect(AIProvider.qwen.baseURL == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
        #expect(AIProvider.deepseek.baseURL == "https://api.deepseek.com/v1")
        #expect(AIProvider.openai.baseURL == "https://api.openai.com/v1")
    }

    @Test func displayNames() {
        #expect(AIProvider.mistral.displayName == "Mistral")
        #expect(AIProvider.qwen.displayName == "Qwen")
        #expect(AIProvider.deepseek.displayName == "DeepSeek")
    }
}
