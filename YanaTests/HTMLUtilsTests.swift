import Foundation
import Testing
import SwiftSoup
@testable import Yana

@Suite("HTMLUtils")
struct HTMLUtilsTests {
    @Test func sanitizeClassNamesRewritesClassAttr() throws {
        let doc = try HTMLUtils.parse("<div class=\"foo bar\">x</div>")
        try HTMLUtils.sanitizeClassNames(doc)
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(html.contains("data-sanitized-class=\"foo bar\""))
        #expect(!html.contains("<div class="))   // the bare class attribute is gone
    }

    @Test func extractMainContentPicksSelectorAndRemoves() throws {
        let html = "<html><body><article><p>Keep</p><div class=\"ad\">Ad</div></article><footer>f</footer></body></html>"
        let out = try HTMLUtils.extractMainContent(html, selector: "article", removeSelectors: [".ad"])
        #expect(out.contains("Keep"))
        #expect(!out.contains("Ad"))
        #expect(!out.contains("<footer"))
    }

    @Test func removeEmptyElementsDropsBlankParagraphs() throws {
        let doc = try HTMLUtils.parse("<p>real</p><p></p><p>   </p>")
        try HTMLUtils.removeEmptyElements(doc, tags: ["p"])
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(html.contains("real"))
        // Only the non-empty paragraph should remain.
        let openParagraphCount = html.components(separatedBy: "<p").count - 1
        #expect(openParagraphCount == 1)
    }

    @Test func removeImageByURLMatchesResponsiveVariant() throws {
        // Basename "photo" (5 chars) > 3 so it matches the server-faithful length guard;
        // the responsive variant suffix -780x438 is stripped before comparison.
        let doc = try HTMLUtils.parse("<img src=\"https://x.com/photo-780x438.jpg\"><p>body</p>")
        try HTMLUtils.removeImageByURL(doc, url: "https://x.com/photo.jpg")
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(!html.contains("<img"))
    }

    // MARK: - Lazy-loaded image de-dup (srcset fallback)

    @Test func removeImageByURLRemovesLazyLoadedImageViaSrcset() throws {
        // Simulates a lazy-loaded image: src is a data: placeholder, real URL only in srcset.
        // Header URL: https://example.com/photo.jpg  → base "photo"
        // Body <img>: src="data:image/svg+xml,x" srcset="https://example.com/photo-336.jpg 336w, https://example.com/photo-1008.jpg 1008w"
        // photo-336 strips dimension suffix (-336) → "photo" (same base) → should be removed.
        let doc = try HTMLUtils.parse(
            "<img src=\"data:image/svg+xml,x\" srcset=\"https://example.com/photo-336.jpg 336w, https://example.com/photo-1008.jpg 1008w\"><p>body</p>"
        )
        try HTMLUtils.removeImageByURL(doc, url: "https://example.com/photo.jpg")
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(!html.contains("<img"), "lazy-loaded image should be removed when srcset matches header URL base filename")
    }

    @Test func removeImageByURLDoesNotRemoveLazyImageWithDifferentBase() throws {
        // A different image (base "banner", not "photo") must NOT be removed.
        let doc = try HTMLUtils.parse(
            "<img src=\"data:image/svg+xml,x\" srcset=\"https://example.com/banner-336.jpg 336w\"><p>body</p>"
        )
        try HTMLUtils.removeImageByURL(doc, url: "https://example.com/photo.jpg")
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(html.contains("<img"), "image with different base filename should NOT be removed")
    }
}
