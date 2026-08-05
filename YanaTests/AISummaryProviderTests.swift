import Foundation
import Testing
@testable import Yana

@Suite("AISummaryProvider", .serialized)
struct AISummaryProviderTests {
    // Every test wraps its whole body in `MockURLProtocol.lock.withLock` -- `.serialized` above
    // only orders tests within THIS suite; it does nothing against other suites (e.g.
    // `YanaAPIClientTests`, `SyncEngineTests`) that share the same static `MockURLProtocol.stub`
    // and which Swift Testing schedules concurrently with this one by default. See
    // `MockURLProtocol.swift` for why an `actor` wouldn't be enough.

    @Test func serverProviderCallsAiPromptAndReturnsTheResponseText() async throws {
        try await MockURLProtocol.lock.withLock {
            var capturedPrompt: String?
            MockURLProtocol.stub = { request in
                capturedPrompt = String(data: request.capturedBody(), encoding: .utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"response":"A concise summary.","provider":"openai","model":"gpt-4o-mini"}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let summary = await provider.summarize(content: "Long article body...", title: "An Article")
            #expect(summary == "A concise summary.")
            #expect(capturedPrompt?.contains("An Article") == true)
        }
    }

    @Test func serverProviderReturnsNilOnRateLimitRatherThanThrowing() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"daily_limit_exceeded","message":"limit reached"}}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let summary = await provider.summarize(content: "x", title: "y")
            #expect(summary == nil)
        }
    }

    @Test func serverProviderReturnsNilOnNoProviderConfigured() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"no_provider_configured","message":"no provider"}}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let summary = await provider.summarize(content: "x", title: "y")
            #expect(summary == nil)
        }
    }

    @Test func serverProviderReturnsNilOnUpstreamProviderError() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"provider_error","message":"upstream failed"}}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let summary = await provider.summarize(content: "x", title: "y")
            #expect(summary == nil)
        }
    }

    @Test func appleIntelligenceProviderReturnsNilWhenModelUnavailable() async {
        struct UnavailableGenerator: ArticleGenerating {
            let availability: AppleIntelligenceAvailability = .deviceNotEligible
            func tokenCount(_ text: String) -> Int { text.count }
            func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
                ProcessedArticle(title: "T", content: "C")
            }
            func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
                "should not be reached"
            }
        }
        let provider = AppleIntelligenceSummaryProvider(generator: UnavailableGenerator())
        let summary = await provider.summarize(content: "<p>body</p>", title: "T")
        #expect(summary == nil)
    }

    @Test func appleIntelligenceProviderReturnsSummaryWhenAvailable() async {
        struct AvailableGenerator: ArticleGenerating {
            let availability: AppleIntelligenceAvailability = .available
            func tokenCount(_ text: String) -> Int { text.count }
            func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
                ProcessedArticle(title: "T", content: "C")
            }
            func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
                "on-device summary"
            }
        }
        let provider = AppleIntelligenceSummaryProvider(generator: AvailableGenerator())
        let summary = await provider.summarize(content: "<p>body</p>", title: "T")
        #expect(summary == "on-device summary")
    }
}

private extension URLRequest {
    /// `URLSession` may deliver the body via `httpBody` or, for some request constructions, via
    /// `httpBodyStream` -- read whichever is present rather than assuming `httpBody` alone.
    func capturedBody() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
