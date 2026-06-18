import Foundation
import Testing
@testable import Yana

@Suite("AppleIntelligenceProcessor")
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

    /// Stateful fake generator that records each generate call with its instructions and prompt.
    final class RecordingGenerator: ArticleGenerating, @unchecked Sendable {
        let availability: AppleIntelligenceAvailability = .available
        var calls: [(instructions: String, prompt: String)] = []
        var mapTransform: @Sendable (String) -> String = { $0 }
        var reduceTransform: @Sendable (String) -> String = { $0 }

        func tokenCount(_ text: String) -> Int { text.count }   // 1 token/char

        func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
            calls.append((instructions: instructions, prompt: prompt))
            if instructions == AppleIntelligenceProcessor.reduceInstructions {
                return ProcessedArticle(title: "REDUCED_TITLE", content: reduceTransform(prompt))
            } else {
                return ProcessedArticle(title: "TITLE", content: mapTransform(prompt))
            }
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
        // Use an HTML with two <p> blocks that together exceed contentBudgetTokens (2496),
        // but each block fits within the budget individually, forcing exactly 2 chunks.
        // The transform maps a prompt to a marker derived from the chunk's unique content,
        // so chunk A (containing "AAAA") yields "[CHUNK:a]" and chunk B (containing "BBBB")
        // yields "[CHUNK:b]" — distinct and order-verifiable.
        var gen = FakeGenerator()
        gen.transform = { prompt in
            if prompt.contains("AAAA") { return "[CHUNK:a]" }
            if prompt.contains("BBBB") { return "[CHUNK:b]" }
            return "[CHUNK:?]"
        }
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 2000)
        // Each block is ~1404 chars → 1404 tokens (1 token/char via FakeGenerator).
        // contentBudgetTokens = max(256, 4096 - 1200 - 400) = 2496.
        // Two 1404-char blocks: combined ≈ 2810 > 2496, each alone = 1404 < 2496 → 2 chunks.
        let blockA = "<p>AAAA" + String(repeating: "a", count: 1397) + "</p>"
        let blockB = "<p>BBBB" + String(repeating: "b", count: 1397) + "</p>"
        let html = blockA + blockB
        let out = await proc.process([article(html)], ai: opts)
        #expect(out.count == 1)
        // Title comes from the first chunk's result.
        #expect(out[0].title == "TITLE")
        // Both distinct chunk markers must appear.
        #expect(out[0].content.contains("[CHUNK:a]"))
        #expect(out[0].content.contains("[CHUNK:b]"))
        // Chunk A (first) must appear before chunk B (second).
        let aRange = out[0].content.range(of: "[CHUNK:a]")
        let bRange = out[0].content.range(of: "[CHUNK:b]")
        if let a = aRange, let b = bRange {
            #expect(a.lowerBound < b.lowerBound)
        } else {
            Issue.record("Expected both [CHUNK:a] and [CHUNK:b] in output content")
        }
    }

    @Test func disabledOptionsReturnInputUnchanged() async {
        let proc = AppleIntelligenceProcessor(generator: FakeGenerator(), temperature: 0.3, maxTokens: 2000)
        let none = AIOptions(summarize: false, improveWriting: false, translate: false, translateLanguage: "English")
        let input = [article("<p>body</p>")]
        #expect(await proc.process(input, ai: none) == input)
    }

    // MARK: - Reduce path tests

    @Test func summarizeMultiChunkTriggersReduceExactlyOnce() async {
        // summarize=true + multi-chunk input → reduce call happens exactly once in the summary pass.
        // HTML must produce ≥2 chunks: two ~1404-char blocks exceed contentBudgetTokens (2496).
        let gen = RecordingGenerator()
        gen.mapTransform = { prompt in
            if prompt.contains("AAAA") { return "[MAP:a]" }
            if prompt.contains("BBBB") { return "[MAP:b]" }
            return "[MAP:?]"
        }
        gen.reduceTransform = { _ in "[REDUCED_CONTENT]" }

        let summarizeOpts = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 2000)
        let blockA = "<p>AAAA" + String(repeating: "a", count: 1397) + "</p>"
        let blockB = "<p>BBBB" + String(repeating: "b", count: 1397) + "</p>"
        let html = blockA + blockB
        let out = await proc.process([article(html)], ai: summarizeOpts)

        let reduceCalls = gen.calls.filter { $0.instructions == AppleIntelligenceProcessor.reduceInstructions }
        // Reduce was called exactly once (inside the summary pass).
        #expect(reduceCalls.count == 1)
        // Summary is populated from the reduce pass; body is unchanged.
        #expect(out.count == 1)
        #expect(out[0].summary == "[REDUCED_CONTENT]")
        // Summarize alone must not rewrite the body or the title.
        #expect(out[0].content == html)
        #expect(out[0].title == "orig")
    }

    @Test func summarizeSingleChunkSkipsReduce() async {
        // summarize=true but only one chunk → reduce call must NOT happen.
        let gen = RecordingGenerator()
        let summarizeOpts = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        // Large budget ensures the short content fits in one chunk.
        let proc = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 2000)
        let out = await proc.process([article("<p>short</p>")], ai: summarizeOpts)

        let reduceCalls = gen.calls.filter { $0.instructions == AppleIntelligenceProcessor.reduceInstructions }
        // No reduce call for single-chunk input.
        #expect(reduceCalls.count == 0)
        // Article is still processed (map ran once).
        #expect(out.count == 1)
    }
}
