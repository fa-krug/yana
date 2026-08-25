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

            let summary = try await provider.summarize(content: "Long article body...", title: "An Article").get()
            #expect(summary == "A concise summary.")
            #expect(capturedPrompt?.contains("An Article") == true)
        }
    }

    @Test func serverProviderReportsTheRateLimitRatherThanThrowing() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"daily_limit_exceeded","message":"limit reached"}}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let result = await provider.summarize(content: "x", title: "y")
            #expect(result == .failure(.limitReached))
        }
    }

    @Test func serverProviderReportsNoProviderConfigured() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"no_provider_configured","message":"no provider"}}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let result = await provider.summarize(content: "x", title: "y")
            #expect(result == .failure(.noProvider))
        }
    }

    @Test func serverProviderReportsAnUpstreamProviderError() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"provider_error","message":"upstream failed"}}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let result = await provider.summarize(content: "x", title: "y")
            #expect(result == .failure(.providerError))
        }
    }


    /// The regression this pins. `yana-server`'s `/api/v1/ai/prompt` rejects any prompt longer than
    /// `ai_max_prompt_length`, whose default is 500 characters, so server-mode summarization failed
    /// for every real article -- and the old "every failure is nil" path reported it as
    /// "Please try again", which can never succeed until the limit is raised on the server.
    @Test func serverProviderReportsAPromptRejectedForLength() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"prompt_too_long","message":"prompt exceeds the configured length limit."}}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            let provider = ServerAISummaryProvider(client: client)

            let result = await provider.summarize(content: String(repeating: "long body. ", count: 200), title: "T")
            #expect(result == .failure(.promptTooLong))
        }
    }

    /// The regression this pins: the server path sent no output-language directive, on the
    /// assumption that a hosted model mirrors the language of the text it is handed. It does not --
    /// it answers in the language of the surrounding instruction, which is English -- so a German
    /// article came back with an English summary.
    @Test func serverProviderAsksForASummaryInTheArticlesLanguage() async {
        await MockURLProtocol.lock.withLock {
            var capturedPrompt = ""
            MockURLProtocol.stub = { request in
                struct Body: Decodable { let prompt: String }
                capturedPrompt = (try? JSONDecoder().decode(Body.self, from: request.capturedBody()).prompt) ?? ""
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"response":"Zusammenfassung.","provider":"openai","model":"m"}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let german = """
            Der Bundestag hat am Mittwoch über den Haushalt beraten. Die Abgeordneten diskutierten \
            mehrere Stunden über die geplanten Ausgaben für Bildung und Verkehr. Am Ende wurde der \
            Entwurf mit knapper Mehrheit an die Ausschüsse zurückverwiesen.
            """
            _ = await ServerAISummaryProvider(client: client).summarize(content: german, title: "Haushalt")
            #expect(capturedPrompt.contains("Write the summary in German"))
        }
    }

    /// The server's limit applies to the whole prompt string, not just the article body: capping
    /// only the content let the instruction header and title push a max-length article back over
    /// the limit, so a long article was rejected even at a correctly-raised server limit.
    @Test func serverProviderCapsTheWholePromptNotJustTheBody() async throws {
        try await MockURLProtocol.lock.withLock {
            var sentPromptLength = 0
            MockURLProtocol.stub = { request in
                struct Body: Decodable { let prompt: String }
                let body = try! JSONDecoder().decode(Body.self, from: request.capturedBody())
                sentPromptLength = body.prompt.count
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"response":"ok","provider":"openai","model":"m"}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let oversized = String(repeating: "a", count: ArticleAIText.maxContentChars + 5000)
            _ = await ServerAISummaryProvider(client: client).summarize(content: oversized, title: "A long title")
            #expect(sentPromptLength == ArticleAIText.maxContentChars)
        }
    }

    /// The server's own per-attempt AI timeout is an operator setting defaulting to 120s, so the
    /// 60s `URLSession` default silently aborted slow-but-successful generations.
    @Test func serverProviderAllowsMoreThanTheDefaultSixtySecondTimeout() async throws {
        try await MockURLProtocol.lock.withLock {
            var sentTimeout: TimeInterval = 0
            MockURLProtocol.stub = { request in
                sentTimeout = request.timeoutInterval
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"response":"ok","provider":"openai","model":"m"}"#.data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            _ = await ServerAISummaryProvider(client: client).summarize(content: "body", title: "T")
            #expect(sentTimeout == ServerAISummaryProvider.requestTimeout)
            #expect(sentTimeout > 60)
        }
    }

    /// A route the server does not have (an older deployment) or a reverse proxy's error page
    /// carries no `{ error: { code } }` envelope. That used to be indistinguishable from being
    /// offline, which is the difference between "your server needs updating" and "try again on
    /// better signal".
    @Test func serverProviderReportsAnUndecodableErrorBodyWithItsStatus() async {
        await MockURLProtocol.lock.withLock {
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
                return (response, "<!DOCTYPE html><title>404</title>".data(using: .utf8)!)
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let result = await ServerAISummaryProvider(client: client).summarize(content: "x", title: "y")
            #expect(result == .failure(.unavailable(detail: "http 404")))
        }
    }

    /// Offline/unexpected-shape failures must not be reported as a server configuration problem.
    @Test func serverProviderReportsTransportFailuresAsUnavailable() {
        #expect(ServerAISummaryProvider.failure(for: .transport) == .unavailable(detail: "network"))
        #expect(ServerAISummaryProvider.failure(for: .unexpectedStatus(500)) == .unavailable(detail: "http 500"))
        #expect(ServerAISummaryProvider.failure(for: .decoding("bad shape")) == .unavailable(detail: "response"))
        #expect(ServerAISummaryProvider.failure(for: .unauthorized) == .unavailable(detail: "auth"))
        // An unknown code is carried through verbatim: this is the only route by which a
        // server-side addition this build has never heard of reaches the user at all.
        #expect(ServerAISummaryProvider.failure(for: .server(YanaAPIError(code: "something_new", message: "")))
                == .unavailable(detail: "something_new"))
    }

    /// Each cause the user can act on gets its own copy; only the catch-all reuses the old text.
    @MainActor
    @Test func everyFailureReasonHasItsOwnMessage() {
        let reasons: [AISummaryFailure] = [.promptTooLong, .noProvider, .limitReached, .providerError,
                                          .unavailable(detail: nil)]
        let messages = reasons.map(ReaderActions.summarizeFailureMessage)
        #expect(Set(messages).count == reasons.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    @Test func appleIntelligenceProviderReportsUnavailableWhenModelUnavailable() async {
        struct UnavailableGenerator: ArticleGenerating {
            let availability: AppleIntelligenceAvailability = .deviceNotEligible
            let supportedLanguages: Set<Locale.Language> = [Locale.Language(identifier: "en"), Locale.Language(identifier: "de")]
            func tokenCount(_ text: String) -> Int { text.count }
            func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
                ProcessedArticle(title: "T", content: "C")
            }
            func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
                "should not be reached"
            }
        }
        let provider = AppleIntelligenceSummaryProvider(generator: UnavailableGenerator())
        let result = await provider.summarize(content: "body", title: "T")
        #expect(result == .failure(.unavailable(detail: "model unavailable")))
    }

    @Test func appleIntelligenceProviderReturnsSummaryWhenAvailable() async {
        struct AvailableGenerator: ArticleGenerating {
            let availability: AppleIntelligenceAvailability = .available
            let supportedLanguages: Set<Locale.Language> = [Locale.Language(identifier: "en"), Locale.Language(identifier: "de")]
            func tokenCount(_ text: String) -> Int { text.count }
            func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
                ProcessedArticle(title: "T", content: "C")
            }
            func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
                "on-device summary"
            }
        }
        let provider = AppleIntelligenceSummaryProvider(generator: AvailableGenerator())
        let result = await provider.summarize(content: "body", title: "T")
        #expect(result == .success("on-device summary"))
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
