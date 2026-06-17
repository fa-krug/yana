import Testing
@testable import Yana

@MainActor
struct ArticleAITextTests {
    @Test func capTruncatesAtBudget() {
        let long = String(repeating: "a", count: ArticleAIText.maxContentChars + 10)
        #expect(ArticleAIText.cap(long).count == ArticleAIText.maxContentChars)
        #expect(ArticleAIText.cap("short") == "short")
    }

    @Test func stripChromeRemovesChrome() throws {
        let html = "<header>h</header><p>body</p><footer>f</footer><script>x</script>"
        let cleaned = try ArticleAIText.stripChrome(html)
        #expect(cleaned.contains("body"))
        #expect(!cleaned.contains("<header>"))
        #expect(!cleaned.contains("<footer>"))
        #expect(!cleaned.contains("<script>"))
    }

    @Test func translateInstructionMentionsLanguage() {
        #expect(ArticleAIText.translateInstruction(language: "German").contains("German"))
    }
}
