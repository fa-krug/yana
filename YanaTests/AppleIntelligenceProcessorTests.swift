import Testing
@testable import Yana

@MainActor
struct AppleIntelligenceProcessorTests {

    /// Fake generator: configurable availability; transforms content per a closure; can throw.
    struct FakeGenerator: ArticleGenerating {
        var availability: AppleIntelligenceAvailability = .available
        var shouldThrow = false
        var transform: @Sendable (String) -> String = { $0 }   // applied to the prompt's content

        func tokenCount(_ text: String) -> Int { text.count }   // 1 token/char

        func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
            if shouldThrow { throw NSError(domain: "test", code: 1) }
            return ProcessedArticle(title: "TITLE", content: transform(prompt))
        }
    }

    func article(_ content: String, title: String = "orig") -> AggregatedArticle {
        AggregatedArticle(title: title, identifier: "id", url: "https://e.com",
                          rawContent: content, content: content, date: .now, author: "", iconURL: nil)
    }

    let opts = AIOptions(summarize: false, improveWriting: true, translate: false, translateLanguage: "English")

    @Test func unavailableModelPassesArticlesThroughUnchanged() async {
        var gen = FakeGenerator(); gen.availability = .deviceNotEligible
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 2000)
        let input = [article("<p>body</p>")]
        let out = await proc.process(input, ai: opts)
        #expect(out == input)   // unchanged, generator never called
    }

    @Test func generationFailureDropsArticle() async {
        var gen = FakeGenerator(); gen.shouldThrow = true
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 2000)
        let out = await proc.process([article("<p>body</p>")], ai: opts)
        #expect(out.isEmpty)
    }

    @Test func emptyContentKeptWithoutCalling() async {
        let proc = AppleIntelligenceProcessor(generator: FakeGenerator(), temperature: 0.3, maxTokens: 2000)
        let input = [article("")]
        let out = await proc.process(input, ai: opts)
        #expect(out == input)
    }

    @Test func mapConcatenatesChunkOutputsAndTakesTitleFromFirstChunk() async {
        // Tiny budget forces multiple chunks; transform marks each processed chunk.
        var gen = FakeGenerator()
        gen.transform = { _ in "<p>X</p>" }
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 5)
        let html = "<p>aaaaaaaaaa</p><p>bbbbbbbbbb</p>"
        let out = await proc.process([article(html)], ai: opts)
        #expect(out.count == 1)
        #expect(out[0].title == "TITLE")
        #expect(out[0].content.contains("X"))
    }

    @Test func disabledOptionsReturnInputUnchanged() async {
        let proc = AppleIntelligenceProcessor(generator: FakeGenerator(), temperature: 0.3, maxTokens: 2000)
        let none = AIOptions(summarize: false, improveWriting: false, translate: false, translateLanguage: "English")
        let input = [article("<p>body</p>")]
        #expect(await proc.process(input, ai: none) == input)
    }
}
