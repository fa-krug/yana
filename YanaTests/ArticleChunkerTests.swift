import Testing
@testable import Yana

@MainActor
struct ArticleChunkerTests {
    // 1 token per character.
    let perChar: (String) -> Int = { $0.count }

    @Test func smallContentIsOneChunk() {
        let chunks = ArticleChunker.chunk(text: "hello", budgetTokens: 1000, tokenCount: perChar)
        #expect(chunks.count == 1)
        #expect(chunks[0].contains("hello"))
    }

    @Test func multipleParagraphsSplitAcrossChunks() {
        // Three paragraphs, budget small enough that each ~lands in its own chunk.
        let text = "aaaaaaaaaa\n\nbbbbbbbbbb\n\ncccccccccc"
        let chunks = ArticleChunker.chunk(text: text, budgetTokens: 20, tokenCount: perChar)
        #expect(chunks.count >= 2)
        let joined = chunks.joined()
        #expect(joined.contains("aaaaaaaaaa"))
        #expect(joined.contains("bbbbbbbbbb"))
        #expect(joined.contains("cccccccccc"))
    }

    @Test func oversizedSingleParagraphIsHardSplit() {
        let big = String(repeating: "x", count: 200)
        let chunks = ArticleChunker.chunk(text: big, budgetTokens: 50, tokenCount: perChar)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { perChar($0) <= 50 * 3 })  // within hard-split char bound
    }

    /// The regression this rewrite fixes. `BlockParser.plainText` joins sections with "\n\n", and
    /// that is the only thing the summarizer is ever handed. The previous HTML-based splitter found
    /// no top-level elements in such a string, fell back to "the whole input is one chunk", and so
    /// silently disabled chunking for every real article -- overflowing the on-device context
    /// window instead of mapping over it.
    @Test func plainTextArticleIsActuallyChunked() {
        let article = (0..<10)
            .map { "Paragraph \($0). " + String(repeating: "word ", count: 20) }
            .joined(separator: "\n\n")
        let chunks = ArticleChunker.chunk(text: article, budgetTokens: 100, tokenCount: perChar)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { perChar($0) <= 300 })
    }
}
