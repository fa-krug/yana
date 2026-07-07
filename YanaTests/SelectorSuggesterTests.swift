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
}
