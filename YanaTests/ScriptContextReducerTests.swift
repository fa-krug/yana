import Foundation
import Testing
@testable import Yana

@Suite("ScriptContextReducer")
struct ScriptContextReducerTests {
    @Test func detectsJSONByContentTypeAndShape() {
        #expect(ScriptContextReducer.looksLikeJSON(body: "{}", contentType: nil))
        #expect(ScriptContextReducer.looksLikeJSON(body: "  [1,2]", contentType: nil))
        #expect(ScriptContextReducer.looksLikeJSON(body: "<html>", contentType: "application/json"))
        #expect(!ScriptContextReducer.looksLikeJSON(body: "<html></html>", contentType: "text/html"))
    }

    @Test func htmlSkeletonDropsNoiseButKeepsStructure() {
        let html = "<html><head><style>p{color:red}</style></head>"
            + "<body><div class='wrap'><script>evil()</script><p>Hello</p></div></body></html>"
        let reduced = ScriptContextReducer.htmlSkeleton(html, maxChars: 5000)
        #expect(!reduced.contains("evil()"))
        #expect(!reduced.contains("color:red"))
        #expect(reduced.contains("wrap"))     // class preserved for selector authoring
        #expect(reduced.contains("Hello"))
    }

    @Test func jsonShapeCapsArraysToTwoElements() throws {
        let reduced = ScriptContextReducer.jsonShape(#"["a","b","c","d","e"]"#, maxChars: 5000)
        let data = try #require(reduced.data(using: .utf8))
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        #expect(array.count == 2)
    }

    @Test func truncatesOversizedContent() {
        let big = String(repeating: "x", count: 100)
        let reduced = ScriptContextReducer.reduce(body: big, contentType: "text/plain", maxChars: 20)
        #expect(reduced.contains("truncated"))
        #expect(reduced.count < big.count)
    }
}
