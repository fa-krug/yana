import Testing
@testable import Yana

struct MacroProcessorTests {
    @Test func substitutesKnownMacrosAndLeavesUnknownVerbatim() throws {
        let out = try MacroProcessor.renderedText(
            withTemplate: "<h1>[[title]]</h1><p>[[missing]]</p>",
            substitutions: ["title": "Hello"]
        )
        #expect(out == "<h1>Hello</h1><p>[[missing]]</p>")
    }

    @Test func emptyDelimiterThrows() {
        #expect(throws: MacroProcessorError.self) {
            _ = try MacroProcessor.renderedText(withTemplate: "x", substitutions: [:], macroStart: "", macroEnd: "]]")
        }
    }
}
