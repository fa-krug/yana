import Testing
@testable import Yana

@MainActor
struct ArticleAITextTests {
    @Test func capTruncatesAtBudget() {
        let long = String(repeating: "a", count: ArticleAIText.maxContentChars + 10)
        #expect(ArticleAIText.cap(long).count == ArticleAIText.maxContentChars)
        #expect(ArticleAIText.cap("short") == "short")
    }

}
