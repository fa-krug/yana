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
                 apiBaseURL: "https://api.openai.com/v1",
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

    @Test func restoresLeadHeaderImageOntoAIOutput() async {
        // stripChrome removes the <header> lead image before the prompt (the model must not
        // translate the image), but the rendered article must keep its header image. Regression:
        // AI-translated Reddit posts were losing their header image entirely.
        let gen = FakeGen([.success(#"{"title":"Neu","content":"<p>übersetzt</p>"}"#)])
        let proc = processor(gen, config: config())
        let header = #"<header style="text-align: center;"><img src="yana-img://lead123" alt="lead"></header>"#
        let out = await proc.process([article("a", content: header + "<p>original</p>")],
                                     ai: ai(translate: true))

        // The prompt still excludes the header (we never send the lead image to the model)…
        #expect(!(gen.prompts.first ?? "").contains("<header"))
        // …but the resulting content keeps the lead image and the translated body.
        #expect(out.first?.content.contains("yana-img://lead123") == true)
        #expect(out.first?.content.contains("übersetzt") == true)
    }

    @Test func promptContainsExactInstructionStrings() async {
        let gen = FakeGen([.success(#"{"title":"T","content":"<p>x</p>"}"#)])
        let proc = processor(gen, config: config())

        _ = await proc.process([article("a")],
                               ai: ai(summarize: true, improve: true, translate: true, language: "German"))

        let p = gen.prompts.first ?? ""
        #expect(p.contains("You must return the result as a JSON object with keys 'title', 'content', and 'summary'."))
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
        // Key responses to article content (not call order): the batch runs concurrently, so a
        // counter-based fake would race. The middle article returns junk → dropped.
        let proc = AIProcessor(config: config(), requestDelay: 0) { prompt, _ in
            if prompt.contains("body2") { return "garbage" }
            if prompt.contains("body1") { return #"{"title":"A","content":"<p>a</p>"}"# }
            return #"{"title":"C","content":"<p>c</p>"}"#
        }
        let input = [article("1", content: "<p>body1</p>"),
                     article("2", content: "<p>body2</p>"),
                     article("3", content: "<p>body3</p>")]

        let out = await proc.process(input, ai: ai(summarize: true))

        #expect(out.map { $0.title } == ["A", "C"])    // middle one dropped, order preserved
    }

    @Test func truncatesOversizedContent() {
        let long = String(repeating: "a", count: ArticleAIText.maxContentChars + 500)
        let capped = ArticleAIText.cap(long)
        #expect(capped.count == ArticleAIText.maxContentChars)
    }

    @Test func leavesSmallContentUnchanged() {
        let short = "short body"
        #expect(ArticleAIText.cap(short) == short)
    }
}

// MARK: - Concurrency tests

/// Tracks how many `generate` calls are in flight at once.
private actor ConcurrencyProbe {
    private(set) var peak = 0
    private var current = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

@Suite("AIProcessor concurrency")
struct AIProcessorConcurrencyTests {
    private func config() -> AIConfig {
        AIConfig(provider: .openai, model: "m", apiKey: "k",
                 apiBaseURL: "https://api.openai.com/v1",
                 temperature: 0.3, maxTokens: 2000, requestTimeout: 120,
                 maxRetries: 3, retryDelay: 0, maxRetryTime: 60)
    }

    private func article(_ id: String, content: String = "<p>body</p>") -> AggregatedArticle {
        AggregatedArticle(title: "T", identifier: id, url: id, rawContent: "",
                          content: content, date: .now, author: "", iconURL: nil)
    }

    private func ai() -> AIOptions {
        AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
    }

    @MainActor
    @Test func aiProcessorOverlapsRequests() async {
        let probe = ConcurrencyProbe()
        let processor = AIProcessor(config: config(), requestDelay: 0) { prompt, _ in
            await probe.enter()
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms — long enough to overlap
            await probe.leave()
            return #"{"title":"t","content":"c"}"#
        }
        let input = (0..<6).map { article("\($0)") }
        _ = await processor.process(input, ai: ai())
        #expect(await probe.peak > 1)
        #expect(await probe.peak <= AIProcessor.maxConcurrentAIRequests)
    }

    @MainActor
    @Test func aiProcessorPreservesOrderAndDropsFailures() async {
        let processor = AIProcessor(config: config(), requestDelay: 0) { prompt, _ in
            // The second article (content "DROP") returns junk → dropped.
            if prompt.contains("DROP") { return "not json" }
            return #"{"title":"ok","content":"c"}"#
        }
        let input = [
            article("a", content: "keep1"),
            article("b", content: "DROP"),
            article("c", content: "keep2"),
        ]
        let out = await processor.process(input, ai: ai())
        #expect(out.map(\.identifier) == ["a", "c"]) // order preserved, "b" dropped
    }
}
