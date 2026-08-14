import Foundation
import Testing
@testable import Yana

/// Pins the chunk → per-chunk-summary → reduce-if-multiple-chunks math extracted from the former
/// `AppleIntelligenceProcessor` (Task 16). These tests are carried over from the deleted
/// `AppleIntelligenceProcessorTests`/`AppleIntelligenceSummaryTests`, adapted to call
/// `AppleIntelligenceChunkedSummarizer.summarize(text:title:generator:)` directly instead of
/// through the now-deleted `AppleIntelligenceProcessor.process(_:ai:)`/`AIOptions`/
/// `AggregatedArticle` machinery.
@Suite("AppleIntelligenceChunkedSummarizer")
struct AppleIntelligenceChunkedSummarizerTests {
    /// Stateful fake generator: records each `generateSummary` call's instructions/prompt.
    /// `generate` (the body-rewrite path) is not exercised by the summarizer at all -- it throws
    /// if called, so any accidental regression back to a shared body/summary path fails loudly.
    final class RecordingGenerator: ArticleGenerating, @unchecked Sendable {
        let availability: AppleIntelligenceAvailability = .available
        var calls: [(instructions: String, prompt: String)] = []
        var mapTransform: @Sendable (String) -> String = { $0 }
        var reduceTransform: @Sendable (String) -> String = { _ in "" }

        func tokenCount(_ text: String) -> Int { text.count }   // 1 token/char

        func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "summarizer must not use the body-rewrite path"])
        }

        func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
            calls.append((instructions: instructions, prompt: prompt))
            if instructions == AppleIntelligenceChunkedSummarizer.reduceInstructions {
                return reduceTransform(prompt)
            } else {
                return mapTransform(prompt)
            }
        }
    }

    @Test func multiChunkTriggersReduceExactlyOnce() async {
        // HTML must produce ≥2 chunks: two ~1404-char blocks exceed contentBudgetTokens (2496).
        let gen = RecordingGenerator()
        gen.mapTransform = { prompt in
            if prompt.contains("AAAA") { return "[MAP:a]" }
            if prompt.contains("BBBB") { return "[MAP:b]" }
            return "[MAP:?]"
        }
        gen.reduceTransform = { _ in "[REDUCED_CONTENT]" }

        let paragraphA = "AAAA" + String(repeating: "a", count: 1397)
        let paragraphB = "BBBB" + String(repeating: "b", count: 1397)
        let text = paragraphA + "\n\n" + paragraphB
        let summary = await AppleIntelligenceChunkedSummarizer.summarize(text: text, title: "orig", generator: gen)

        let reduceCalls = gen.calls.filter { $0.instructions == AppleIntelligenceChunkedSummarizer.reduceInstructions }
        #expect(reduceCalls.count == 1)
        #expect(summary == "[REDUCED_CONTENT]")
    }

    @Test func singleChunkSkipsReduce() async {
        let gen = RecordingGenerator()
        gen.mapTransform = { _ in "short summary" }
        let summary = await AppleIntelligenceChunkedSummarizer.summarize(text: "short", title: "orig", generator: gen)

        let reduceCalls = gen.calls.filter { $0.instructions == AppleIntelligenceChunkedSummarizer.reduceInstructions }
        #expect(reduceCalls.count == 0)
        #expect(summary == "short summary")
    }

    @Test func generationFailureReturnsNilRatherThanThrowing() async {
        struct ThrowingGenerator: ArticleGenerating {
            let availability: AppleIntelligenceAvailability = .available
            func tokenCount(_ text: String) -> Int { text.count }
            func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
                throw NSError(domain: "test", code: 1)
            }
            func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
                throw NSError(domain: "test", code: 1)
            }
        }
        let summary = await AppleIntelligenceChunkedSummarizer.summarize(text: "body", title: "T", generator: ThrowingGenerator())
        #expect(summary == nil)
    }

    @Test func summaryNeverUsesTheBodyRewritePath() async {
        // A model that honors the (unused-here) ProcessedArticle @Guide would echo the full body
        // if the summarizer ever routed through `generate`. Regression guard for the bug this
        // caught previously: summaries collapsing into the article body verbatim.
        struct StructurePreservingGenerator: ArticleGenerating {
            let availability: AppleIntelligenceAvailability = .available
            func tokenCount(_ text: String) -> Int { max(1, text.count / 4) }
            func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
                ProcessedArticle(title: "T", content: prompt)   // would echo the full body if ever called
            }
            func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
                "a real summary"
            }
        }
        let body = "The quick brown fox jumps over the lazy dog."
        let summary = await AppleIntelligenceChunkedSummarizer.summarize(text: body, title: "T", generator: StructurePreservingGenerator())
        #expect(summary == "a real summary")
    }
}
