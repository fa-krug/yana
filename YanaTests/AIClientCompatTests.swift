import Foundation
import Testing
@testable import Yana

struct AIClientCompatTests {
    private func config(_ provider: AIProvider, baseURL: String) -> AIConfig {
        AIConfig(provider: provider, model: "m", apiKey: "k", apiBaseURL: baseURL,
                 temperature: 0.3, maxTokens: 100, requestTimeout: 30,
                 maxRetries: 0, retryDelay: 0, maxRetryTime: 10)
    }

    /// Capture the outgoing request and return a canned OpenAI-shaped success body.
    private func captureClient(_ cfg: AIConfig, capture: @escaping @Sendable (URLRequest) -> Void) -> AIClient {
        AIClient(config: cfg) { request in
            capture(request)
            let body = #"{"choices":[{"message":{"content":"{\"title\":\"t\",\"content\":\"c\"}"}}]}"#
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }
    }

    @Test func mistralHitsMistralBaseURLWithBearerAuth() async throws {
        let cfg = config(.mistral, baseURL: AIProvider.mistral.baseURL)
        nonisolated(unsafe) var captured: URLRequest?
        let client = captureClient(cfg) { captured = $0 }
        _ = try await client.generate(prompt: "p", jsonMode: true)
        #expect(captured?.url?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
        #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func deepseekAndQwenUseTheSameBuilder() async throws {
        for p in [AIProvider.deepseek, .qwen] {
            let cfg = config(p, baseURL: p.baseURL)
            nonisolated(unsafe) var captured: URLRequest?
            let client = captureClient(cfg) { captured = $0 }
            _ = try await client.generate(prompt: "p", jsonMode: true)
            #expect(captured?.url?.absoluteString == "\(p.baseURL)/chat/completions")
        }
    }
}
