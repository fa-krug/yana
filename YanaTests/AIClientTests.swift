import Foundation
import Testing
@testable import Yana

@Suite("AIClient")
struct AIClientTests {
    /// Records the request and returns a canned (Data, HTTPURLResponse). No live network.
    private final class FetchRecorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var responses: [(Data, Int)]          // (body, statusCode) consumed in order
        var index = 0
        init(_ responses: [(Data, Int)]) { self.responses = responses }

        func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let (data, code) = responses[min(index, responses.count - 1)]
            index += 1
            let http = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (data, http)
        }
    }

    private func config(provider: AIProvider, model: String = "m", key: String = "k") -> AIConfig {
        AIConfig(
            provider: provider,
            model: model,
            apiKey: key,
            openaiAPIURL: "https://api.openai.com/v1",
            temperature: 0.3,
            maxTokens: 2000,
            requestTimeout: 120,
            maxRetries: 3,
            retryDelay: 0,            // 0 => no real sleeping in tests
            maxRetryTime: 60
        )
    }

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        try #require(request.httpBody).withUnsafeBytes { _ in }
        let obj = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        return try #require(obj)
    }

    @Test func openaiBuildsChatCompletionsRequestAndParsesChoice() async throws {
        let body = #"{"choices":[{"message":{"content":"{\"title\":\"T\",\"content\":\"C\"}"}}]}"#
        let rec = FetchRecorder([(Data(body.utf8), 200)])
        let client = AIClient(config: config(provider: .openai), fetch: rec.fetch)

        let result = try await client.generate(prompt: "hello", jsonMode: true)

        #expect(result == #"{"title":"T","content":"C"}"#)
        let req = try #require(rec.requests.first)
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let json = try bodyJSON(req)
        #expect(json["model"] as? String == "m")
        #expect(json["temperature"] as? Double == 0.3)
        #expect(json["max_tokens"] as? Int == 2000)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "hello")
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
    }

    @Test func anthropicBuildsMessagesRequestAndParsesContent() async throws {
        let body = #"{"content":[{"type":"text","text":"answer"}]}"#
        let rec = FetchRecorder([(Data(body.utf8), 200)])
        let client = AIClient(config: config(provider: .anthropic), fetch: rec.fetch)

        let result = try await client.generate(prompt: "hi", jsonMode: true)

        #expect(result == "answer")
        let req = try #require(rec.requests.first)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let json = try bodyJSON(req)
        #expect(json["model"] as? String == "m")
        #expect(json["max_tokens"] as? Int == 2000)
        #expect(json["temperature"] as? Double == 0.3)
        #expect(json["response_format"] == nil)     // Anthropic has no JSON-mode flag
    }

    @Test func geminiBuildsGenerateContentRequestWithUppercaseSchemaAndParsesText() async throws {
        let body = #"{"candidates":[{"content":{"parts":[{"text":"gem"}]}}]}"#
        let rec = FetchRecorder([(Data(body.utf8), 200)])
        let client = AIClient(config: config(provider: .gemini), fetch: rec.fetch)

        let result = try await client.generate(prompt: "g", jsonMode: true)

        #expect(result == "gem")
        let req = try #require(rec.requests.first)
        #expect(req.url?.absoluteString ==
            "https://generativelanguage.googleapis.com/v1beta/models/m:generateContent")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        let json = try bodyJSON(req)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "g")
        let gen = try #require(json["generationConfig"] as? [String: Any])
        #expect(gen["temperature"] as? Double == 0.3)
        #expect(gen["maxOutputTokens"] as? Int == 2000)
        #expect(gen["responseMimeType"] as? String == "application/json")
        let schema = try #require(gen["responseSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "OBJECT")          // uppercase per server
        let props = try #require(schema["properties"] as? [String: Any])
        let titleProp = try #require(props["title"] as? [String: Any])
        #expect(titleProp["type"] as? String == "STRING")
        #expect(schema["required"] as? [String] == ["title", "content"])
    }

    @Test func retriesOn429ThenSucceeds() async throws {
        let ok = #"{"choices":[{"message":{"content":"done"}}]}"#
        let rec = FetchRecorder([(Data("rate".utf8), 429), (Data(ok.utf8), 200)])
        let client = AIClient(config: config(provider: .openai), fetch: rec.fetch)

        let result = try await client.generate(prompt: "p", jsonMode: true)

        #expect(result == "done")
        #expect(rec.requests.count == 2)        // retried exactly once after the 429
    }

    @Test func nonRetryableStatusFailsImmediately() async throws {
        let rec = FetchRecorder([(Data("boom".utf8), 500)])
        let client = AIClient(config: config(provider: .openai), fetch: rec.fetch)

        await #expect(throws: AIClientError.self) {
            _ = try await client.generate(prompt: "p", jsonMode: true)
        }
        #expect(rec.requests.count == 1)        // 500 is not retried
    }

    @Test func exhausting429RetriesThrows() async throws {
        let rec = FetchRecorder([
            (Data("x".utf8), 429), (Data("x".utf8), 429),
            (Data("x".utf8), 429), (Data("x".utf8), 429),
        ])
        let client = AIClient(config: config(provider: .openai), fetch: rec.fetch)

        await #expect(throws: AIClientError.self) {
            _ = try await client.generate(prompt: "p", jsonMode: true)
        }
        #expect(rec.requests.count == 4)        // 1 initial + maxRetries(3)
    }
}
