# Phase 4f — AI Post-Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the server's optional per-feed AI post-processing — summarize / improve-writing / translate via OpenAI, Anthropic, or Gemini — onto the device. A new `AIClient` talks to the three providers (JSON mode, 429-only retry with backoff, injectable fetch so tests never touch the network); a new `AIProcessor` ports `base.py::_apply_ai_processing` exactly (gate, header/footer/nav/script/style strip, the verbatim prompt, robust JSON extraction, and **drop-the-article-on-failure**); and `AggregationService` gains an injectable `aiProcessor` that runs **after** the run cap and **before** upsert.

**Architecture:** `AggregationService` stays on `@MainActor`. Before each run it snapshots an immutable `Sendable` `AIConfig` (provider, model, key, API URL, knobs) from `AppSettings` + `KeychainService` on the main actor, and hands it to the `AIProcessor`, which runs off the main actor over the `Sendable` `[AggregatedArticle]` list. The processor strips HTML with the Phase 4b `HTMLUtils`/SwiftSoup, builds the prompt, calls `AIClient` (whose only side effect is an injectable `fetch` closure), parses the JSON robustly, and returns the possibly-shorter list (dropped articles omitted). When AI is disabled or unconfigured, the processor returns its input unchanged. The service then upserts the processed list exactly as in Phase 4a.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor` / `Sendable`), SwiftData, SwiftSoup (from Phase 4b), Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§5, decision 5).
**Depends on:** Phase 4a (`AggregationService`, `FeedConfig`, `AggregatedArticle`, `AggregatorOptions.ai`), Phase 4b (`HTMLUtils` SwiftSoup utilities).

---

## File Structure

- Create `Yana/Services/AIClient.swift` — `AIConfig` snapshot, `AIProvider`-keyed request builder, three provider calls, 429-only retry, injectable fetch.
- Create `Yana/Services/AIProcessor.swift` — `AIProcessing` protocol + concrete `AIProcessor`; the ported `_apply_ai_processing` pipeline (gate, strip, prompt, JSON extraction, drop-on-failure, per-article delay).
- Modify `Yana/Services/AggregationService.swift` — add an injectable `aiProcessor`, build the default from `AppSettings` + `KeychainService`, call it after `capped` and before `ArticleUpsert.apply`.
- Create `YanaTests/AIClientTests.swift` — provider request shape + response parsing + 429 retry, all via a canned fetch closure (no network).
- Create `YanaTests/AIProcessorTests.swift` — gate, strip, prompt, JSON extraction, drop-on-failure, no-op-when-disabled, with a fake `AIClient`.
- Modify `YanaTests/AggregationServiceTests.swift` — add wiring tests with a fake `AIProcessing`.

Build/test commands used throughout:

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

To run a single suite, append `-only-testing:YanaTests/<SuiteType>`.

---

## Task 1: `AIConfig` snapshot + `AIClient` request/response for all three providers

**Files:**
- Create: `Yana/Services/AIClient.swift`
- Test: `YanaTests/AIClientTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AIClientTests.swift`:

```swift
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
            "https://generativelanguage.googleapis.com/v1beta/models/m:generateContent?key=k")
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIClientTests`
Expected: FAIL — `cannot find 'AIConfig' / 'AIClient' / 'AIClientError' in scope`.

- [ ] **Step 3: Implement `AIConfig` + `AIClient`**

Create `Yana/Services/AIClient.swift`:

```swift
import Foundation

/// Immutable, `Sendable` snapshot of the AI configuration for one run. Built on the main
/// actor from `AppSettings` + `KeychainService`, then handed to off-main code. `provider`
/// is resolved to a concrete one (`.openai`/`.anthropic`/`.gemini`); `.none` means AI is off
/// and no `AIClient` is constructed.
struct AIConfig: Sendable, Equatable {
    var provider: AIProvider
    var model: String
    var apiKey: String
    var openaiAPIURL: String
    var temperature: Double
    var maxTokens: Int
    var requestTimeout: Int
    var maxRetries: Int
    var retryDelay: Int
    /// Total seconds the retry loop may consume before giving up (server `ai_max_retry_time`).
    var maxRetryTime: Int
}

enum AIClientError: Error, Equatable {
    case unsupportedProvider          // .none reached the client (programmer error)
    case httpStatus(Int)              // non-2xx, non-retryable, or retries exhausted
    case invalidResponseShape         // provider JSON did not contain the expected text path
}

/// Talks to one of three LLM providers in JSON mode. The only side effect is the injected
/// `fetch` closure (defaults to `URLSession`), so tests supply canned responses with no
/// live network. Retries on HTTP 429 only, with exponential backoff capped by a time budget.
struct AIClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let config: AIConfig
    let fetch: Fetch

    init(config: AIConfig, fetch: @escaping Fetch = AIClient.defaultFetch) {
        self.config = config
        self.fetch = fetch
    }

    static let defaultFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponseShape
        }
        return (data, http)
    }

    /// Generate a response from the active provider. `jsonMode` requests structured JSON
    /// where the provider supports it. Returns the raw text payload (still a JSON string for
    /// our prompts); throws on transport / status / shape failure.
    func generate(prompt: String, jsonMode: Bool) async throws -> String {
        let (request, parse) = try buildRequest(prompt: prompt, jsonMode: jsonMode)
        let data = try await send(request)
        return try parse(data)
    }

    // MARK: - Request building (per provider)

    private func buildRequest(
        prompt: String,
        jsonMode: Bool
    ) throws -> (URLRequest, @Sendable (Data) throws -> String) {
        switch config.provider {
        case .openai: return (try openaiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseOpenAI)
        case .anthropic: return (try anthropicRequest(prompt: prompt), Self.parseAnthropic)
        case .gemini: return (try geminiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseGemini)
        case .none: throw AIClientError.unsupportedProvider
        }
    }

    private func jsonRequest(url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(config.requestTimeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func openaiRequest(prompt: String, jsonMode: Bool) throws -> URLRequest {
        guard let url = URL(string: "\(config.openaiAPIURL)/chat/completions") else {
            throw AIClientError.invalidResponseShape
        }
        var body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        return try jsonRequest(url: url, headers: ["Authorization": "Bearer \(config.apiKey)"], body: body)
    }

    private func anthropicRequest(prompt: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIClientError.invalidResponseShape
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
        ]
        return try jsonRequest(
            url: url,
            headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
            body: body
        )
    }

    private func geminiRequest(prompt: String, jsonMode: Bool) throws -> URLRequest {
        let model = config.model
        let key = config.apiKey
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")
        else { throw AIClientError.invalidResponseShape }

        var generationConfig: [String: Any] = [
            "temperature": config.temperature,
            "maxOutputTokens": config.maxTokens,
        ]
        if jsonMode {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = [
                "type": "OBJECT",
                "properties": [
                    "title": ["type": "STRING"],
                    "content": ["type": "STRING"],
                ],
                "required": ["title", "content"],
            ]
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig,
        ]
        return try jsonRequest(url: url, headers: [:], body: body)
    }

    // MARK: - Response parsing (per provider)

    private static let parseOpenAI: @Sendable (Data) throws -> String = { data in
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw AIClientError.invalidResponseShape }
        return content
    }

    private static let parseAnthropic: @Sendable (Data) throws -> String = { data in
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = obj["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String
        else { throw AIClientError.invalidResponseShape }
        return text
    }

    private static let parseGemini: @Sendable (Data) throws -> String = { data in
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { throw AIClientError.invalidResponseShape }
        return text
    }

    // MARK: - Send with 429-only retry + backoff + time budget

    private func send(_ request: URLRequest) async throws -> Data {
        let start = Date()
        var attempt = 0
        while true {
            let (data, http) = try await fetch(request)
            if (200..<300).contains(http.statusCode) {
                return data
            }
            // Retry on 429 only, while attempts remain.
            guard http.statusCode == 429, attempt < config.maxRetries else {
                throw AIClientError.httpStatus(http.statusCode)
            }
            // Exponential backoff: retryDelay * 2^attempt, capped by the total time budget.
            let wait = config.retryDelay > 0 ? Double(config.retryDelay) * pow(2, Double(attempt)) : 0
            let elapsed = Date().timeIntervalSince(start)
            if wait > 0, elapsed + wait > Double(config.maxRetryTime) {
                throw AIClientError.httpStatus(http.statusCode)
            }
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            attempt += 1
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIClientTests`
Expected: PASS (all six tests). The `retryDelay: 0` in the fixture means `Task.sleep` is skipped, so retry tests run instantly.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AIClient.swift YanaTests/AIClientTests.swift
git commit -m "feat: AIClient — OpenAI/Anthropic/Gemini JSON mode with 429 retry, injectable fetch"
```

---

## Task 2: `AIProcessor` — gate, strip, prompt, JSON extraction, drop-on-failure

**Files:**
- Create: `Yana/Services/AIProcessor.swift`
- Test: `YanaTests/AIProcessorTests.swift`

This task ports `core/aggregators/base.py::_apply_ai_processing` verbatim (lines ~287–438): the
gate, the `header/footer/nav/script/style` strip, the exact instruction strings, the uppercase
JSON schema (delegated to `AIClient`), the robust JSON extraction (direct → ```` ```json ````
block → first `{`…last `}`), the per-article delay, and the **drop-article-on-failure** rule.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AIProcessorTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AIProcessor")
struct AIProcessorTests {
    /// Fake AIClient text generator: records prompts, returns scripted outputs (or throws).
    private final class FakeGen: @unchecked Sendable {
        var prompts: [String] = []
        var outputs: [Result<String, Error>]
        var index = 0
        init(_ outputs: [Result<String, Error>]) { self.outputs = outputs }
        func generate(prompt: String, jsonMode: Bool) async throws -> String {
            prompts.append(prompt)
            defer { index += 1 }
            return try outputs[min(index, outputs.count - 1)].get()
        }
    }

    private func config(provider: AIProvider = .openai, key: String = "k") -> AIConfig {
        AIConfig(provider: provider, model: "m", apiKey: key,
                 openaiAPIURL: "https://api.openai.com/v1",
                 temperature: 0.3, maxTokens: 2000, requestTimeout: 120,
                 maxRetries: 3, retryDelay: 0, maxRetryTime: 60)
    }

    private func article(_ id: String, title: String = "T", content: String = "<p>body</p>") -> AggregatedArticle {
        AggregatedArticle(title: title, identifier: id, url: id, rawContent: "",
                          content: content, date: .now, author: "", iconURL: nil)
    }

    private func ai(summarize: Bool = false, improve: Bool = false, translate: Bool = false,
                    language: String = "English") -> AIOptions {
        AIOptions(summarize: summarize, improveWriting: improve, translate: translate, translateLanguage: language)
    }

    // Build a processor whose AIClient uses the fake generator.
    private func processor(_ gen: FakeGen, config: AIConfig) -> AIProcessor {
        AIProcessor(config: config, requestDelay: 0, generate: gen.generate)
    }

    @Test func disabledOptionsReturnInputUnchanged() async {
        let gen = FakeGen([])
        let proc = processor(gen, config: config())
        let input = [article("a"), article("b")]

        let out = await proc.process(input, ai: ai())   // all toggles off

        #expect(out == input)
        #expect(gen.prompts.isEmpty)          // AI never called
    }

    @Test func noProviderReturnsInputUnchanged() async {
        let gen = FakeGen([])
        let proc = processor(gen, config: config(provider: .none))
        let input = [article("a")]

        let out = await proc.process(input, ai: ai(summarize: true))

        #expect(out == input)
        #expect(gen.prompts.isEmpty)
    }

    @Test func missingKeyReturnsInputUnchanged() async {
        let gen = FakeGen([])
        let proc = processor(gen, config: config(key: ""))
        let input = [article("a")]

        let out = await proc.process(input, ai: ai(summarize: true))

        #expect(out == input)
        #expect(gen.prompts.isEmpty)
    }

    @Test func successUpdatesTitleAndContent() async {
        let gen = FakeGen([.success(#"{"title":"New","content":"<p>new</p>"}"#)])
        let proc = processor(gen, config: config())

        let out = await proc.process([article("a", title: "Old", content: "<p>old</p>")],
                                     ai: ai(summarize: true))

        #expect(out.count == 1)
        #expect(out.first?.title == "New")
        #expect(out.first?.content == "<p>new</p>")
    }

    @Test func stripsHeaderFooterNavScriptStyleBeforeSending() async {
        let gen = FakeGen([.success(#"{"title":"T","content":"<p>x</p>"}"#)])
        let proc = processor(gen, config: config())
        let messy = "<header>H</header><nav>N</nav><script>s()</script><style>.a{}</style><footer>F</footer><p>keep</p>"

        _ = await proc.process([article("a", content: messy)], ai: ai(improve: true))

        let prompt = gen.prompts.first ?? ""
        #expect(prompt.contains("keep"))
        #expect(!prompt.contains("<header>"))
        #expect(!prompt.contains("<nav>"))
        #expect(!prompt.contains("<script>"))
        #expect(!prompt.contains("<style>"))
        #expect(!prompt.contains("<footer>"))
    }

    @Test func promptContainsExactInstructionStrings() async {
        let gen = FakeGen([.success(#"{"title":"T","content":"<p>x</p>"}"#)])
        let proc = processor(gen, config: config())

        _ = await proc.process([article("a")],
                               ai: ai(summarize: true, improve: true, translate: true, language: "German"))

        let p = gen.prompts.first ?? ""
        #expect(p.contains("You must return the result as a JSON object with keys 'title' and 'content'."))
        #expect(p.contains("Summarize the article content concisely."))
        #expect(p.contains("Keep all links (<a> tags) exactly as they are"))
        #expect(p.contains("Translate the title and content to German."))
        #expect(p.contains("Do NOT translate link labels"))
        #expect(p.contains("CRITICAL: Preserve ALL HTML tags and structure in your output."))
        #expect(p.contains("Input Data:"))
    }

    @Test func extractsJSONFromCodeFence() async {
        let fenced = "```json\n{\"title\":\"F\",\"content\":\"<p>f</p>\"}\n```"
        let gen = FakeGen([.success(fenced)])
        let proc = processor(gen, config: config())

        let out = await proc.process([article("a")], ai: ai(summarize: true))

        #expect(out.first?.title == "F")
        #expect(out.first?.content == "<p>f</p>")
    }

    @Test func extractsJSONFromSurroundingProse() async {
        let messy = "Sure! Here is the result: {\"title\":\"P\",\"content\":\"<p>p</p>\"} Hope that helps."
        let gen = FakeGen([.success(messy)])
        let proc = processor(gen, config: config())

        let out = await proc.process([article("a")], ai: ai(summarize: true))

        #expect(out.first?.title == "P")
        #expect(out.first?.content == "<p>p</p>")
    }

    @Test func dropsArticleOnInvalidJSON() async {
        let gen = FakeGen([.success("totally not json")])
        let proc = processor(gen, config: config())

        let out = await proc.process([article("a")], ai: ai(summarize: true))

        #expect(out.isEmpty)        // drop-on-failure
    }

    @Test func dropsArticleOnClientError() async {
        struct Boom: Error {}
        let gen = FakeGen([.failure(Boom())])
        let proc = processor(gen, config: config())

        let out = await proc.process([article("a")], ai: ai(summarize: true))

        #expect(out.isEmpty)
    }

    @Test func emptyContentArticleKeptWithoutCallingAI() async {
        let gen = FakeGen([])
        let proc = processor(gen, config: config())

        let out = await proc.process([article("a", content: "")], ai: ai(summarize: true))

        #expect(out.count == 1)          // kept as-is (server: appends unchanged)
        #expect(gen.prompts.isEmpty)     // AI not called for empty content
    }

    @Test func processesMultipleArticlesDroppingOnlyFailures() async {
        let gen = FakeGen([
            .success(#"{"title":"A","content":"<p>a</p>"}"#),
            .success("garbage"),
            .success(#"{"title":"C","content":"<p>c</p>"}"#),
        ])
        let proc = processor(gen, config: config())

        let out = await proc.process([article("1"), article("2"), article("3")], ai: ai(summarize: true))

        #expect(out.map(\.title) == ["A", "C"])    // middle one dropped
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests`
Expected: FAIL — `cannot find 'AIProcessor' in scope` (and `AIProcessing`).

- [ ] **Step 3: Implement `AIProcessing` + `AIProcessor`**

Create `Yana/Services/AIProcessor.swift`:

```swift
import Foundation
import SwiftSoup

/// Applies optional AI post-processing to a batch of aggregated articles. Off-main,
/// `Sendable`, no SwiftData. Ported from the server's `_apply_ai_processing`.
protocol AIProcessing: Sendable {
    /// Returns the processed list. When AI is disabled / unconfigured, returns `input`
    /// unchanged. On per-article AI failure or invalid JSON, that article is DROPPED.
    func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle]
}

/// Concrete processor. Holds an `AIConfig` snapshot and a text generator (defaults to an
/// `AIClient`, but tests inject a fake). `requestDelay` is the per-article pause (seconds).
struct AIProcessor: AIProcessing {
    typealias Generate = @Sendable (_ prompt: String, _ jsonMode: Bool) async throws -> String

    let config: AIConfig
    let requestDelay: Int
    let generate: Generate

    /// Default: drive a real `AIClient` built from the snapshot.
    init(config: AIConfig, requestDelay: Int) {
        self.config = config
        self.requestDelay = requestDelay
        let client = AIClient(config: config)
        self.generate = client.generate
    }

    /// Injectable generator for tests.
    init(config: AIConfig, requestDelay: Int, generate: @escaping Generate) {
        self.config = config
        self.requestDelay = requestDelay
        self.generate = generate
    }

    func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
        // Gate: at least one toggle on, a concrete provider, and a non-empty key.
        let anyEnabled = ai.summarize || ai.improveWriting || ai.translate
        guard anyEnabled, config.provider != .none, !config.apiKey.isEmpty else {
            return input
        }

        var output: [AggregatedArticle] = []
        for (i, article) in input.enumerated() {
            if i > 0, requestDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(requestDelay) * 1_000_000_000)
            }

            // Empty content: keep unchanged, do not call AI (server parity).
            guard !article.content.isEmpty else {
                output.append(article)
                continue
            }

            let cleanHTML = (try? Self.stripChrome(article.content)) ?? article.content
            let prompt = Self.buildPrompt(title: article.title, cleanHTML: cleanHTML, ai: ai)

            do {
                let raw = try await generate(prompt, true)
                guard let parsed = Self.extractJSON(raw) else { continue }   // drop on invalid JSON
                var updated = article
                if let title = parsed["title"] as? String { updated.title = title }
                if let content = parsed["content"] as? String { updated.content = content }
                output.append(updated)
            } catch {
                continue        // drop on AI failure
            }
        }
        return output
    }

    // MARK: - HTML chrome strip (header/footer/nav/script/style)

    static func stripChrome(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        for tag in ["header", "footer", "nav", "script", "style"] {
            try doc.select(tag).remove()
        }
        // Match the server's `str(soup)`: the full (sanitized) document HTML.
        return try doc.html()
    }

    // MARK: - Prompt assembly (exact server instruction strings)

    static func buildPrompt(title: String, cleanHTML: String, ai: AIOptions) -> String {
        var parts: [String] = []

        parts.append(
            "You are an AI assistant that processes article content. "
            + "You will receive an article title and content in HTML format. "
            + "You must return the result as a JSON object with keys 'title' and 'content'. "
            + "Do not include any markdown formatting (like ```json) in the response, just the raw JSON string."
        )

        if ai.summarize {
            parts.append("Summarize the article content concisely.")
        }

        if ai.improveWriting {
            parts.append(
                "Rewrite the content to improve clarity, flow, and style. "
                + "IMPORTANT: Preserve the complete HTML structure including all tags. "
                + "Keep all links (<a> tags) exactly as they are - do not modify href attributes or remove any links. "
                + "Only improve the text content itself."
            )
        }

        if ai.translate {
            let targetLang = ai.translateLanguage.isEmpty ? "English" : ai.translateLanguage
            parts.append(
                "Translate the title and content to \(targetLang). "
                + "IMPORTANT: Do NOT translate link labels (the text inside <a> tags). "
                + "Keep link text in the original language. Only translate regular text content."
            )
        }

        parts.append(
            "The input content is HTML with stripped headers/footers. "
            + "CRITICAL: Preserve ALL HTML tags and structure in your output. "
            + "This includes: links (<a>), paragraphs (<p>), headings (<h1>-<h6>), lists (<ul>, <ol>, <li>), "
            + "images (<img>), divs, spans, and all other HTML elements. "
            + "Your output 'content' field must be valid HTML with the exact same structure as the input."
        )

        let inputData: [String: String] = ["title": title, "content": cleanHTML]
        let inputJSON = (try? JSONSerialization.data(withJSONObject: inputData, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return parts.joined(separator: "\n") + "\n\nInput Data:\n" + inputJSON
    }

    // MARK: - Robust JSON extraction (direct -> ```json``` block -> first{..last})

    static func extractJSON(_ raw: String) -> [String: Any]? {
        if let parsed = parseObject(raw) { return parsed }

        // ```json ... ``` (or plain ``` ... ```) fenced block.
        if let fenced = firstFencedJSON(in: raw), let parsed = parseObject(fenced) {
            return parsed
        }

        // First '{' to last '}'.
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end {
            let candidate = String(raw[start...end])
            if let parsed = parseObject(candidate) { return parsed }
        }
        return nil
    }

    private static func parseObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Mirrors the server regex ```` ```(?:json)?\s*(\{.*?\})\s*``` ```` (DOTALL).
    private static func firstFencedJSON(in raw: String) -> String? {
        let pattern = "```(?:json)?\\s*(\\{[\\s\\S]*?\\})\\s*```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: raw)
        else { return nil }
        return String(raw[captured])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AIProcessorTests`
Expected: PASS (all thirteen tests).

> Fidelity note (`stripChrome`): the server does `str(soup)` over a `BeautifulSoup` parse,
> which wraps fragments in `<html><body>…</body></html>`. SwiftSoup's `doc.html()` does the
> same wrapping. The prompt assertions check for *presence/absence of substrings* (`"keep"`,
> `"<header>"`), not an exact byte match, so this wrapping difference is intentional and
> harmless — the downstream LLM is instructed to preserve structure regardless of the wrapper.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AIProcessor.swift YanaTests/AIProcessorTests.swift
git commit -m "feat: AIProcessor — gate, chrome strip, ported prompt, robust JSON, drop-on-failure"
```

---

## Task 3: Wire `AIProcessor` into `AggregationService` (after cap, before upsert)

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Modify: `YanaTests/AggregationServiceTests.swift`

The 4a service computes `capped` then calls `ArticleUpsert.apply(capped, …)`. AI slots in
between: `let processed = await aiProcessor.process(capped, ai: config.options.ai)`, then
upsert `processed`. The processor is injectable; the default builds an `AIConfig` snapshot
on the main actor from `AppSettings` + `KeychainService` and wraps it in an `AIProcessor`.

- [ ] **Step 1: Write the failing wiring tests**

Add to `YanaTests/AggregationServiceTests.swift` (inside the existing `AggregationServiceTests`
suite, alongside the 4a tests). These use a fake `AIProcessing` so no AIClient/network runs:

```swift
    // MARK: - AI wiring (Phase 4f)

    /// Fake processor: records what it received and returns a scripted transform.
    private final class FakeAIProcessor: AIProcessing, @unchecked Sendable {
        var received: [AggregatedArticle] = []
        var receivedAI: AIOptions?
        let transform: @Sendable ([AggregatedArticle]) -> [AggregatedArticle]
        init(transform: @escaping @Sendable ([AggregatedArticle]) -> [AggregatedArticle] = { $0 }) {
            self.transform = transform
        }
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
            received = input
            receivedAI = ai
            return transform(input)
        }
    }

    @Test func aiProcessorRunsAfterCapAndBeforeUpsert() async throws {
        let context = try makeContext()
        // dailyLimit 2 so the cap trims the 3 fetched down to 2 BEFORE the processor sees them.
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)

        let fake = FakeAIProcessor()    // identity transform
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in
                FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
            },
            aiProcessor: fake
        )
        await service.update(feed: feed)

        #expect(fake.received.count == 2)                       // saw the capped list, not 3
        #expect(fake.received.map(\.identifier) == ["1", "2"])
        #expect(feed.articles.count == 2)
    }

    @Test func aiProcessorOutputIsWhatGetsUpserted() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)

        // Processor drops "drop" and rewrites "keep"'s title.
        let fake = FakeAIProcessor { input in
            input.compactMap { a in
                guard a.identifier != "drop" else { return nil }
                var copy = a
                copy.title = "AI:\(a.title)"
                return copy
            }
        }
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in
                FakeAggregator(articles: [self.aggregated("keep"), self.aggregated("drop")])
            },
            aiProcessor: fake
        )
        await service.update(feed: feed)

        #expect(feed.articles.map(\.identifier) == ["keep"])    // dropped article never upserted
        #expect(feed.articles.first?.title == "AI:keep")        // AI transform persisted
    }

    @Test func aiProcessorReceivesFeedsAIOptions() async throws {
        let context = try makeContext()
        var options = FeedContentOptions()
        options.ai = AIOptions(summarize: true, improveWriting: false, translate: true, translateLanguage: "German")
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        feed.options = .feedContent(options)
        context.insert(feed)

        let fake = FakeAIProcessor()
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x")]) },
            aiProcessor: fake
        )
        await service.update(feed: feed)

        #expect(fake.receivedAI?.summarize == true)
        #expect(fake.receivedAI?.translate == true)
        #expect(fake.receivedAI?.translateLanguage == "German")
    }
```

> The fixture references `FakeAggregator`, `aggregated(_:)`, and `makeContext()` already
> defined by the 4a suite. If `Feed.options` cannot be assigned post-init in the current model,
> set it through whatever initializer/parameter Phase 1 exposes — adapt only the construction
> line, not the assertions.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests`
Expected: FAIL — the `AggregationService(context:makeAggregator:aiProcessor:)` initializer and the `AIProcessing` parameter do not exist yet.

- [ ] **Step 3: Wire the processor into the service**

In `Yana/Services/AggregationService.swift`:

1. Add the stored dependency and a default-building initializer. Replace the property block and
   `init` with:

```swift
    private let context: ModelContext
    private let makeAggregator: AggregatorFactory
    private let aiProcessor: AIProcessing
    private let now: () -> Date

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        // Default: snapshot AppSettings + Keychain on the main actor into an AIProcessor.
        self.aiProcessor = aiProcessor ?? AIProcessor(
            config: Self.makeAIConfig(settings: AppSettings()),
            requestDelay: AppSettings().aiRequestDelay
        )
        self.now = now
    }
```

2. Add the main-actor `AIConfig` builder (reads the real `AppSettings` per-provider properties
   and the matching Keychain key — provider/model/key resolution is explicit, no guessing):

```swift
    /// Build the `AIConfig` snapshot from settings + Keychain. Returns a `.none`-provider
    /// config when AI is off; the processor then no-ops. Per-provider model + key are read
    /// from the dedicated AppSettings properties and the matching Keychain item.
    static func makeAIConfig(settings: AppSettings) -> AIConfig {
        let provider = settings.activeAIProvider
        let model: String
        let keyItem: KeychainService.APIKeyItem?
        switch provider {
        case .none:
            model = ""
            keyItem = nil
        case .openai:
            model = settings.openaiModel
            keyItem = .openaiAPIKey
        case .anthropic:
            model = settings.anthropicModel
            keyItem = .anthropicAPIKey
        case .gemini:
            model = settings.geminiModel
            keyItem = .geminiAPIKey
        }
        let key = keyItem.flatMap { KeychainService.loadAPIKey(for: $0) } ?? ""
        return AIConfig(
            provider: provider,
            model: model,
            apiKey: key,
            openaiAPIURL: settings.openaiAPIURL,
            temperature: settings.aiTemperature,
            maxTokens: settings.aiMaxTokens,
            requestTimeout: settings.aiRequestTimeout,
            maxRetries: settings.aiMaxRetries,
            retryDelay: settings.aiRetryDelay,
            maxRetryTime: 60
        )
    }
```

3. In `aggregate(feed:)`, insert the AI step between `capped` and the upsert:

```swift
            let capped = Array(fresh.prefix(cap))
            let processed = await aiProcessor.process(capped, ai: config.options.ai)
            ArticleUpsert.apply(processed, to: feed, starredTag: starredTag(), context: context, now: runNow)
```

(Leave everything else in `aggregate(feed:)` — validate, fetch, intake filter, cap, `lastFetchedAt`,
`lastError` — exactly as Phase 4a defined it.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests`
Expected: PASS (the 4a tests still pass — their default-factory path returns `nil` before AI runs — plus the three new wiring tests).

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS. (`AIClientTests`, `AIProcessorTests`, the augmented `AggregationServiceTests`, and all earlier-phase suites. Existing `AggregationService(context:)` call sites in the views still compile — the new parameters are defaulted.)

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat: wire AIProcessor into AggregationService (after cap, before upsert)"
```

---

## Notes & deliberate divergences

- **Daily / monthly AI limits are NOT enforced.** `AppSettings.aiDefaultDailyLimit` /
  `aiDefaultMonthlyLimit` remain stored but unused — server parity (the server stores them but
  this port does not gate on them). Do not add enforcement in this phase.
- **Model lists stay in iOS code.** `AIProvider.models` already lists current iOS model ids; the
  server's stale `choices` lists are not ported. The processor/client use whatever
  `settings.<provider>Model` holds.
- **`update(article:)`** re-runs the whole owning feed (Phase 4a behavior), so single-article
  pull-down refresh already passes through `aiProcessor.process` via `aggregate(feed:)`. No extra
  wiring needed here; a true single-article AI re-run can be revisited if `update(article:)` is
  later narrowed.
- **`maxRetryTime`** has no dedicated `AppSettings` property; it is fixed at the server default
  (60s) in `makeAIConfig`. If a setting is later added, thread it through `AIConfig.maxRetryTime`.
- **`openaiEnabled`/`anthropicEnabled`/`geminiEnabled`** flags exist in `AppSettings` but the
  active-provider gate (`activeAIProvider != .none` + non-empty key) is the effective switch,
  matching the server (`active_ai_provider` is the master toggle). The per-provider `*_enabled`
  flags govern the settings UI, not the run-time gate; do not add them to the gate here.
- **Anthropic has no JSON-mode request flag** (server omits `response_format` for Anthropic);
  the schema is enforced only via the prompt instructions. The robust JSON extraction in the
  processor is what makes all three providers safe.

---

## Self-Review

**Spec coverage (4f scope, §5 + decision 5):**
- Three providers with exact request/response shapes — OpenAI `chat/completions` + `Bearer` +
  `response_format` json; Anthropic `v1/messages` + `x-api-key` + `anthropic-version`;
  Gemini `generateContent?key=` + `responseMimeType` + uppercase `responseSchema` — Task 1.
- 429-only retry with exponential backoff capped by a time budget; non-429 fails immediately;
  injectable fetch so tests have no live network — Task 1.
- Gate (any toggle on **and** active provider **and** key present); strip
  header/footer/nav/script/style; verbatim prompt strings; uppercase JSON schema; robust JSON
  extraction (direct → fenced → first`{`…last`}`); per-article `aiRequestDelay`;
  **drop-article-on-failure / invalid JSON** — Task 2.
- Wired into `AggregationService` after the run cap, before upsert; injectable processor;
  default built from `AppSettings` + `KeychainService` on the main actor; no-op when disabled —
  Task 3.
- Daily/monthly limits stored-but-unenforced; model lists kept in iOS code — Notes.

**Placeholders:** none — every step has complete Swift, canned JSON fixtures, an exact command, and an expected result.

**Type consistency:** `AIConfig` (memberwise, used identically in Tasks 1/2/3), `AIClient(config:fetch:)`, `AIClient.generate(prompt:jsonMode:)`, `AIClientError`, `AIProcessing.process(_:ai:)`, `AIProcessor(config:requestDelay:[generate:])`, and `AggregationService(context:makeAggregator:aiProcessor:now:)` are referenced with matching signatures across tasks and tests. `AIProvider`, `AIOptions`, `AggregatorOptions.ai`, `FeedContentOptions`, `KeychainService.APIKeyItem`, and `AppSettings`' per-provider properties match the real source files read for this plan.

**Fidelity risks (verify during implementation):**
- `stripChrome` HTML wrapping differs from BeautifulSoup's `str(soup)` only in document
  envelope; assertions test substrings, and the LLM is told to preserve structure — acceptable.
- The fenced-JSON regex uses `[\s\S]*?` (Swift has no DOTALL flag) to mirror Python's
  `re.DOTALL` non-greedy capture — behaviorally equivalent for the single-block case.
- `Feed.options` assignment in Task 3's third test assumes a settable `options` (Phase 1);
  adapt the construction line if the model requires init-time assignment.
