import Foundation
import Testing
@testable import Yana

@Suite("SelectorSuggester")
struct SelectorSuggesterTests {
    @Test func parsesJSONObject() {
        let text = #"{"selectors": ["article", ".body"]}"#
        #expect(SelectorSuggester.parseSelectors(from: text) == ["article", ".body"])
    }

    @Test func parsesBareArray() {
        let text = #"["main", ".content"]"#
        #expect(SelectorSuggester.parseSelectors(from: text) == ["main", ".content"])
    }

    @Test func extractsJSONFromSurroundingProse() {
        let text = "Sure! Here are the selectors:\n```json\n{\"selectors\": [\"article\"]}\n```\nHope that helps."
        #expect(SelectorSuggester.parseSelectors(from: text) == ["article"])
    }

    @Test func trimsDedupesAndDropsEmpties() {
        let text = #"{"selectors": ["  article ", "article", "", ".body"]}"#
        #expect(SelectorSuggester.parseSelectors(from: text) == ["article", ".body"])
    }

    @Test func returnsEmptyOnUnparseableText() {
        #expect(SelectorSuggester.parseSelectors(from: "no json here").isEmpty)
    }

    @Test func promptIncludesCandidatesAndHTML() {
        let prompt = SelectorSuggester.prompt(for: .content, pageHTML: "<article>hi</article>",
                                              current: ["article", ".old"])
        #expect(prompt.contains("article, .old"))
        #expect(prompt.contains("<article>hi</article>"))
        #expect(prompt.contains("selectors"))
    }

    @Test func instructionsDifferByKind() {
        #expect(SelectorSuggester.instructions(for: .content) != SelectorSuggester.instructions(for: .ignore))
    }

    @Test func ignoreInstructionsCoverAffiliateAndNavNoise() {
        let instr = SelectorSuggester.instructions(for: .ignore).lowercased()
        #expect(instr.contains("anzeige"))
        #expect(instr.contains("affiliate"))
        #expect(instr.contains("sponsor"))
    }

    @Test func compactStripsScriptsStylesAndHead() {
        let html = """
        <html><head><style>.x{}</style><script>var a=1</script></head>
        <body><article><script>track()</script><p class="body">Text</p>
        <div class="ad-affiliate">Anzeige</div></article><noscript>x</noscript></body></html>
        """
        let compacted = SelectorSuggester.compactForAnalysis(html)
        #expect(!compacted.contains("track()"))
        #expect(!compacted.contains("var a=1"))
        #expect(!compacted.contains(".x{}"))
        // The class-bearing body markup the model needs to select survives.
        #expect(compacted.contains("class=\"body\""))
        #expect(compacted.contains("ad-affiliate"))
    }
}
