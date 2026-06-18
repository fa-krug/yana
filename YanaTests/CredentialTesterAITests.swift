import Testing
@testable import Yana

struct CredentialTesterAITests {
    @Test func openaiUsesOverrideURL() {
        #expect(CredentialTester.aiBaseURL(provider: .openai, openaiAPIURL: "https://x/v1") == "https://x/v1")
    }

    @Test func compatibleProvidersUseFixedBase() {
        #expect(CredentialTester.aiBaseURL(provider: .mistral, openaiAPIURL: "https://x/v1") == AIProvider.mistral.baseURL)
        #expect(CredentialTester.aiBaseURL(provider: .qwen, openaiAPIURL: "ignored") == AIProvider.qwen.baseURL)
        #expect(CredentialTester.aiBaseURL(provider: .deepseek, openaiAPIURL: "ignored") == AIProvider.deepseek.baseURL)
    }
}
