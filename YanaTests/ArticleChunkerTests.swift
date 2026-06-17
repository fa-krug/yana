import Testing
@testable import Yana

@MainActor
struct ArticleChunkerTests {
    // 1 token per character.
    let perChar: (String) -> Int = { $0.count }

    @Test func smallContentIsOneChunk() {
        let chunks = ArticleChunker.chunk(html: "<p>hello</p>", budgetTokens: 1000, tokenCount: perChar)
        #expect(chunks.count == 1)
        #expect(chunks[0].contains("hello"))
    }

    @Test func multipleBlocksSplitAcrossChunks() {
        // Three paragraphs, budget small enough that each ~lands in its own chunk.
        let html = "<p>aaaaaaaaaa</p><p>bbbbbbbbbb</p><p>cccccccccc</p>"
        let chunks = ArticleChunker.chunk(html: html, budgetTokens: 20, tokenCount: perChar)
        #expect(chunks.count >= 2)
        let joined = chunks.joined()
        #expect(joined.contains("aaaaaaaaaa"))
        #expect(joined.contains("bbbbbbbbbb"))
        #expect(joined.contains("cccccccccc"))
    }

    @Test func oversizedSingleBlockIsHardSplit() {
        let big = "<p>" + String(repeating: "x", count: 200) + "</p>"
        let chunks = ArticleChunker.chunk(html: big, budgetTokens: 50, tokenCount: perChar)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { perChar($0) <= 50 * 3 })  // within hard-split char bound
    }
}
