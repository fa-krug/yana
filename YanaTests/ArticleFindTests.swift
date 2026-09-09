import Foundation
import Testing
import UIKit
@testable import Yana

/// Pins the pure half of "Find in Article" (`ArticleFind.swift`): that the searchable units follow
/// the renderer's own segmentation, that matching is forgiving and in document order, and that
/// refining a query keeps the reader on the match under them instead of snapping around.
@Suite("ArticleFind")
struct ArticleFindTests {

    private func p(_ text: String) -> Block { .paragraph([InlineRun(text: text)]) }

    /// One of every render path: a lead image with a caption, a summary card, a coalesced text run
    /// (paragraph + heading), a list, a code block, a blockquote, and a divider with no text at all.
    private var body: [Block] {
        [
            .image(ref: "yana-img://lead", caption: [InlineRun(text: "   "), InlineRun(text: "Lead caption")]),
            .summary([p("Summary text")]),
            p("Alpha paragraph"),
            .heading(level: 2, runs: [InlineRun(text: "Beta "), InlineRun(text: "heading", styles: .bold)]),
            .list(ordered: false, items: [[p("Gamma item")], [p("Delta item")]]),
            .codeBlock(text: "let epsilon = 1", language: "swift"),
            .blockquote([p("Zeta quote")]),
            .divider,
        ]
    }

    private func index(_ blocks: [Block]) -> ArticleFindIndex {
        ArticleFindIndex(segments: BodySegment.segments(from: blocks, summaryPending: false))
    }

    // MARK: - Units

    @Test func unitsFollowTheRenderersSegmentation() {
        let units = index(body).units
        #expect(units.map(\.id) == [
            FindUnitID(segment: 0),                 // lead image caption
            FindUnitID(segment: 1, path: [0]),      // summary card's paragraph
            FindUnitID(segment: 2, path: [0]),      // text run, block 0
            FindUnitID(segment: 2, path: [1]),      // text run, block 1
            FindUnitID(segment: 3, path: [0, 0]),   // list item 0, block 0
            FindUnitID(segment: 3, path: [1, 0]),   // list item 1, block 0
            FindUnitID(segment: 4),                 // code block
            FindUnitID(segment: 5, path: [0]),      // blockquote's paragraph
        ])
        #expect(units.map(\.text) == [
            "Lead caption", "Summary text", "Alpha paragraph", "Beta heading",
            "Gamma item", "Delta item", "let epsilon = 1", "Zeta quote",
        ])
        #expect(units.map(\.ordinal) == Array(0..<8))
    }

    @Test func onlyTheSegmentsOneTextViewIsFineScrollable() {
        let units = index(body).units
        #expect(units.map(\.isTextViewBacked) == [true, false, true, true, false, false, true, false])
    }

    @Test func textRunOffsetsMatchTheMergedAttributedString() {
        let run: [Block] = [p("Alpha paragraph"), .heading(level: 2, runs: [InlineRun(text: "Beta "), InlineRun(text: "heading")])]
        let units = index(run).units
        #expect(units.map(\.textViewOffset) == [0, 16])   // "Alpha paragraph" is 15 UTF-16 units + "\n"

        let merged = ReaderAttributedText.make(blocks: run, baseSize: 17, design: .default).string as NSString
        #expect(merged.substring(from: units[1].textViewOffset).hasPrefix("Beta heading"))
    }

    @Test func aWhitespaceOnlyCaptionIsNotAUnit() {
        let units = index([.image(ref: "yana-img://x", caption: [InlineRun(text: " \n ")]), p("Body")]).units
        #expect(units.map(\.text) == ["Body"])
    }

    // MARK: - Matching

    @Test func matchingIsCaseAndDiacriticInsensitiveAndInDocumentOrder() {
        let matches = index([p("Über uns"), p("uber alles, UBER"), .list(ordered: true, items: [[p("Nothing")], [p("über")]])])
            .matches(for: "uber")
        #expect(matches.map(\.unit) == [
            FindUnitID(segment: 0, path: [0]),
            FindUnitID(segment: 0, path: [1]), FindUnitID(segment: 0, path: [1]),
            FindUnitID(segment: 1, path: [1, 0]),
        ])
        #expect(matches.map(\.range.location) == [0, 0, 12, 0])
        #expect(matches.map(\.unitOrdinal) == [0, 1, 1, 3])
    }

    @Test func blankQueriesMatchNothing() {
        let idx = index([p("anything at all")])
        #expect(idx.matches(for: "").isEmpty)
        #expect(idx.matches(for: "   ").isEmpty)
        #expect(idx.matches(for: "\n").isEmpty)
    }

    @Test func matchesWithinAUnitDoNotOverlap() {
        #expect(index([p("aaaa")]).matches(for: "aa").map(\.range.location) == [0, 2])
    }

    @Test func aTextRunMatchKnowsItsRangeInTheMergedString() {
        let match = index([p("Alpha paragraph"), p("Beta")]).matches(for: "beta")[0]
        #expect(match.range == NSRange(location: 0, length: 4))
        #expect(match.textViewRange == NSRange(location: 16, length: 4))
    }

    // MARK: - State

    @Test func typingSelectsTheFirstMatchAndRefiningKeepsTheOneUnderTheReader() {
        let idx = index([p("cat scatter cat")])
        var state = ArticleFindState()

        state.update(query: "c", in: idx)
        #expect(state.matches.map(\.range.location) == [0, 5, 12])
        #expect(state.status == .match(current: 1, total: 3))

        state.update(query: "ca", in: idx)
        #expect(state.current?.range.location == 0)

        state.next()
        #expect(state.current?.range.location == 5)
        #expect(state.status == .match(current: 2, total: 3))

        // Still matches at the same spot: stay there.
        state.update(query: "cat", in: idx)
        #expect(state.current?.range.location == 5)

        // Only "scatter" still matches, at the same spot: stay there, now 1 of 1.
        state.update(query: "catt", in: idx)
        #expect(state.current?.range.location == 5)
        #expect(state.status == .match(current: 1, total: 1))

        state.update(query: "cats", in: idx)
        #expect(state.current == nil)
        #expect(state.status == .noMatches)

        // Nothing to anchor on any more: back to the first match.
        state.update(query: "cat", in: idx)
        #expect(state.current?.range.location == 0)
    }

    @Test func aRefinementThatBreaksTheCurrentMatchMovesForwardNotBackToTheTop() {
        let idx = index([p("apple banana apricot")])
        var state = ArticleFindState()
        state.update(query: "a", in: idx)
        #expect(state.matches.map(\.range.location) == [0, 7, 9, 11, 13])
        state.next()
        #expect(state.current?.range.location == 7)

        state.update(query: "ap", in: idx)
        #expect(state.matches.map(\.range.location) == [0, 13])
        #expect(state.current?.range.location == 13, "the first match at or after where the reader was, not the top")
    }

    @Test func nextAndPreviousWrapAround() {
        let idx = index([p("a b a")])
        var state = ArticleFindState()
        state.update(query: "a", in: idx)
        #expect(state.status == .match(current: 1, total: 2))
        state.previous()
        #expect(state.status == .match(current: 2, total: 2))
        state.next()
        #expect(state.status == .match(current: 1, total: 2))
    }

    @Test func statusIsIdleWithoutAQueryAndStepsAreNoOpsWithoutMatches() {
        let idx = index([p("text")])
        var state = ArticleFindState()
        #expect(state.status == .idle)
        state.update(query: "zzz", in: idx)
        state.next()
        state.previous()
        #expect(state.current == nil)
        #expect(state.status == .noMatches)
    }

    @Test func highlightsMarkEveryMatchAndSingleOutTheCurrentOne() {
        let idx = index([p("cat scatter cat"), p("no cats here")])
        var state = ArticleFindState()
        state.update(query: "cat", in: idx)
        state.next()
        let highlights = state.highlights

        let first = highlights.ranges(for: FindUnitID(segment: 0, path: [0]))
        #expect(first.map(\.range.location) == [0, 5, 12])
        #expect(first.map(\.isCurrent) == [false, true, false])
        #expect(highlights.ranges(for: FindUnitID(segment: 0, path: [1])).map(\.isCurrent) == [false])
        #expect(highlights.ranges(for: FindUnitID(segment: 7)).isEmpty)
        #expect(!highlights.isEmpty)
        #expect(FindHighlights.empty.isEmpty)
    }

    // MARK: - Painting

    @Test func mergedHighlightsLandOnTheBlockTheyBelongTo() {
        let run: [Block] = [p("Alpha paragraph"), p("Beta")]
        let text = ReaderAttributedText.make(blocks: run, baseSize: 17, design: .default) { block in
            block == 1 ? [FindHighlightRange(range: NSRange(location: 0, length: 4), isCurrent: true)] : []
        }
        var effective = NSRange()
        let color = text.attribute(.backgroundColor, at: 16, effectiveRange: &effective) as? UIColor
        #expect(color != nil)
        #expect(effective == NSRange(location: 16, length: 4))
        #expect(text.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test func aHighlightThatDoesNotFitTheTextIsSkipped() {
        let text = ReaderAttributedText.make(string: "short", size: 17, design: .default,
                                             highlights: [FindHighlightRange(range: NSRange(location: 3, length: 40), isCurrent: false)])
        #expect(text.attribute(.backgroundColor, at: 3, effectiveRange: nil) == nil)
    }
}
