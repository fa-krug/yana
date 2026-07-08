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

    // A "be thorough" ignore-list reply can open with reasoning prose whose brackets precede the
    // real JSON. The first bracketed fragment is unparseable prose; parsing must skip it and reach
    // the actual object rather than giving up (which surfaced as "the AI returned no selectors").
    @Test func skipsLeadingProseBracketsToReachJSON() {
        let text = "I found these noise blocks: [ads, share buttons, related]. "
            + #"Here is the JSON: {"selectors": [".advertisement", ".related-articles"]}"#
        #expect(SelectorSuggester.parseSelectors(from: text) == [".advertisement", ".related-articles"])
    }

    @Test func skipsLeadingProseObjectToReachJSON() {
        let text = #"Reasoning {step: one}. Final: {"selectors": [".ad"]}"#
        #expect(SelectorSuggester.parseSelectors(from: text) == [".ad"])
    }

    // A JSON object truncated by the token cap has no closing brace; parsing returns empty rather
    // than hanging or mis-parsing a stray inner bracket.
    @Test func returnsEmptyOnTruncatedJSON() {
        let text = #"{"selectors": [".advertisement", ".ad"#
        #expect(SelectorSuggester.parseSelectors(from: text).isEmpty)
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

    // Reasoning models (e.g. DeepSeek v4) spend hidden reasoning_tokens out of the same completion
    // budget. The verbose "be thorough" ignore instruction can burn ~2500 tokens on reasoning alone,
    // so the user's default 2000-token budget leaves nothing for the JSON reply and the model returns
    // empty content (finish_reason=length). The selector call must floor the budget well above that.
    @Test func tokenBudgetFloorsBelowReasoningCeiling() {
        // A user's summarization budget too small for reasoning + reply is raised to the floor.
        #expect(SelectorSuggester.tokenBudget(userMax: 2000) == SelectorSuggester.minSelectorTokens)
        #expect(SelectorSuggester.tokenBudget(userMax: 500) == SelectorSuggester.minSelectorTokens)
        // The floor is comfortably above the worst observed reasoning burn (~2500).
        #expect(SelectorSuggester.minSelectorTokens >= 4096)
        // A user who already allows more keeps their larger budget.
        #expect(SelectorSuggester.tokenBudget(userMax: 8000) == 8000)
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
