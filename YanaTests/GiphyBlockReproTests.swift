import Foundation
import Testing
@testable import Yana

/// Regression tests for the "Giphy in Reddit not working" bug: the Reddit aggregator emits
/// images (Giphy link posts, gallery items, comment GIFs) as `<p><img></p>`, but BlockParser
/// used to drop images wrapped in a paragraph — the GIF was downloaded and cached, then
/// discarded at the Block layer so the reader never showed it.
@Suite("GiphyBlockRepro")
struct GiphyBlockReproTests {
    private func hasImage(_ blocks: [Block], ref: String) -> Bool {
        func walk(_ bs: [Block]) -> Bool {
            for b in bs {
                switch b {
                case .image(let r, _) where r == ref: return true
                case .blockquote(let inner): if walk(inner) { return true }
                case .list(_, let items): for it in items { if walk(it) { return true } }
                default: break
                }
            }
            return false
        }
        return walk(blocks)
    }

    /// Exact shape the aggregator's addLinkMedia produces for a Giphy link post.
    @Test func giphyImageWrappedInParagraphSurvives() {
        let blocks = BlockParser.blocks(fromHTML: #"<p><img src="yana-img://cf87abc" alt="Giphy" /></p>"#)
        #expect(hasImage(blocks, ref: "yana-img://cf87abc"))
    }

    /// A bare <img> (already supported) still works.
    @Test func bareGiphyImageSurvives() {
        let blocks = BlockParser.blocks(fromHTML: #"<img src="yana-img://bare1" alt="Giphy">"#)
        #expect(hasImage(blocks, ref: "yana-img://bare1"))
    }

    /// Giphy inside a Reddit comment (rendered as blockquote > div > p > img).
    @Test func giphyImageInsideCommentBlockquoteSurvives() {
        let html = #"<blockquote><div><p>lol</p><p><img src="yana-img://cmt1" alt="Giphy"></p></div></blockquote>"#
        let blocks = BlockParser.blocks(fromHTML: html)
        #expect(hasImage(blocks, ref: "yana-img://cmt1"))
    }

    /// A paragraph with both text and a trailing image keeps the text and the image.
    @Test func paragraphWithTextAndImageKeepsBoth() {
        let blocks = BlockParser.blocks(fromHTML: #"<p>See <strong>this</strong> <img src="yana-img://mix1"></p>"#)
        #expect(hasImage(blocks, ref: "yana-img://mix1"))
        #expect(blocks.contains { if case .paragraph = $0 { return true }; return false })
    }

    /// A plain text paragraph produces exactly one paragraph block (no spurious image blocks).
    @Test func plainParagraphUnaffected() {
        let blocks = BlockParser.blocks(fromHTML: "<p>just text</p>")
        #expect(blocks.count == 1)
        #expect(!blocks.contains { if case .image = $0 { return true }; return false })
    }
}
