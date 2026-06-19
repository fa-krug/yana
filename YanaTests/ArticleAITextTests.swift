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

    @Test func leadingHeaderHTMLReturnsHeaderBlock() throws {
        let html = #"<header style="text-align:center;"><img src="yana-img://lead"></header><p>body</p>"#
        let header = try ArticleAIText.leadingHeaderHTML(html)
        #expect(header?.contains("yana-img://lead") == true)
        #expect(header?.contains("<header") == true)
        #expect(header?.contains("<p>") == false)   // body excluded
    }

    @Test func leadingHeaderHTMLNilWhenNoHeader() throws {
        #expect(try ArticleAIText.leadingHeaderHTML("<p>just body</p>") == nil)
    }

    @Test func translateInstructionMentionsLanguage() {
        #expect(ArticleAIText.translateInstruction(language: "German").contains("German"))
    }
}
