import Foundation
import Testing
import SwiftSoup
@testable import Yana

@Suite("HTMLUtils")
struct HTMLUtilsTests {
    @Test func removesLeadingHeadingDuplicatingTitle() throws {
        let doc = try HTMLUtils.parse("<article><h1>Breaking: Big News Today</h1><p>Body text.</p></article>")
        try HTMLUtils.removeDuplicateTitleHeading(doc, title: "Breaking: Big News Today")
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(!html.contains("<h1>"))
        #expect(html.contains("Body text."))
    }

    @Test func removesHeadingWhenTitleIsWhitespaceOrCaseVariant() throws {
        let doc = try HTMLUtils.parse("<article><h1>  Big   News  Today </h1><p>x</p></article>")
        try HTMLUtils.removeDuplicateTitleHeading(doc, title: "big news today")
        #expect(!(try HTMLUtils.bodyHTML(doc)).contains("<h1>"))
    }

    @Test func keepsHeadingThatDiffersFromTitle() throws {
        let doc = try HTMLUtils.parse("<article><h1>Something Completely Different</h1><p>x</p></article>")
        try HTMLUtils.removeDuplicateTitleHeading(doc, title: "Breaking: Big News Today")
        #expect((try HTMLUtils.bodyHTML(doc)).contains("<h1>"))
    }

    @Test func doesNothingWhenTitleEmpty() throws {
        let doc = try HTMLUtils.parse("<article><h1>Heading</h1></article>")
        try HTMLUtils.removeDuplicateTitleHeading(doc, title: "")
        #expect((try HTMLUtils.bodyHTML(doc)).contains("<h1>"))
    }

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

    @Test func extractMainContentUnionsMultipleSelectors() throws {
        // Content distributed across two separate containers is combined (OR).
        let html = "<html><body><div class=\"lead\"><p>Lead</p></div>"
            + "<div class=\"body\"><p>Body</p></div><aside>side</aside></body></html>"
        let out = try HTMLUtils.extractMainContent(html, contentSelectors: [".lead", ".body"], removeSelectors: [])
        #expect(out.contains("Lead"))
        #expect(out.contains("Body"))
        #expect(!out.contains("side"))
    }

    @Test func extractMainContentDropsNestedDuplicateMatches() throws {
        // `main` wraps `article`; keeping the outermost avoids duplicating the inner text.
        let html = "<html><body><main><article><p>Once</p></article></main></body></html>"
        let out = try HTMLUtils.extractMainContent(html, contentSelectors: ["main", "article"], removeSelectors: [])
        // "Once" appears exactly one time (outer match only, not doubled).
        let occurrences = out.components(separatedBy: "Once").count - 1
        #expect(occurrences == 1)
    }

    @Test func extractMainContentRemovesAllIgnoreMatches() throws {
        let html = "<html><body><article><p>Keep</p><div class=\"ad\">A</div>"
            + "<div class=\"promo\">B</div></article></body></html>"
        let out = try HTMLUtils.extractMainContent(html, contentSelectors: ["article"], removeSelectors: [".ad", ".promo"])
        #expect(out.contains("Keep"))
        #expect(!out.contains(">A<"))
        #expect(!out.contains(">B<"))
    }

    @Test func extractMainContentFallsBackToBodyWhenNoMatch() throws {
        let html = "<html><body><p>Only body</p></body></html>"
        let out = try HTMLUtils.extractMainContent(html, contentSelectors: [".missing"], removeSelectors: [])
        #expect(out.contains("Only body"))
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

    // MARK: - Sanitization (Tier 1: unsafe tags + attributes)

    @Test func removeUnsafeTagsStripsScriptStyleNoscript() throws {
        let doc = try HTMLUtils.parse(
            "<p>keep</p><script>alert(1)</script><style>.x{}</style><noscript>n</noscript>"
        )
        try HTMLUtils.removeUnsafeTags(doc)
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(html.contains("keep"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<style"))
        #expect(!html.contains("<noscript"))
    }

    @Test func removeUnsafeTagsKeepsYouTubeIframeDropsOthers() throws {
        let doc = try HTMLUtils.parse(
            "<iframe src=\"https://www.youtube-nocookie.com/embed/abc\"></iframe>"
            + "<iframe src=\"https://ads.example.com/track\"></iframe>"
        )
        try HTMLUtils.removeUnsafeTags(doc)
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(html.contains("youtube-nocookie.com"), "YouTube embed must be preserved")
        #expect(!html.contains("ads.example.com"), "non-YouTube iframe must be dropped")
    }

    @Test func removeUnsafeAttributesStripsHandlersAndJavascriptURLs() throws {
        let doc = try HTMLUtils.parse(
            "<a href=\"javascript:alert(1)\" onclick=\"x()\">a</a><img src=\"yana-img://h\" onerror=\"y()\">"
        )
        try HTMLUtils.removeUnsafeAttributes(doc)
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(!html.contains("onclick"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("yana-img://h"), "safe src must be preserved")
    }

    // MARK: - Sanitization (Tier 2: presentational cruft)

    @Test func removeInlineStylesDropsStyleAttribute() throws {
        let doc = try HTMLUtils.parse("<p style=\"color:red\">x</p>")
        try HTMLUtils.removeInlineStyles(doc)
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(!html.contains("style="))
        #expect(html.contains(">x<"))
    }

    @Test func removeTrackingPixelsDropsTinyImagesKeepsRealOnes() throws {
        let doc = try HTMLUtils.parse(
            "<img src=\"a\" width=\"1\" height=\"1\"><img src=\"b\" width=\"600\" height=\"400\">"
        )
        try HTMLUtils.removeTrackingPixels(doc)
        let html = try HTMLUtils.bodyHTML(doc)
        #expect(!html.contains("src=\"a\""), "1x1 tracking pixel must be removed")
        #expect(html.contains("src=\"b\""), "real image must be kept")
    }

    // MARK: - Sanitization (Tier 3: compaction)

    @Test func compactDisablesPrettyPrint() throws {
        let doc = try HTMLUtils.parse("<div><p>x</p></div>")
        HTMLUtils.compact(doc)
        #expect(doc.outputSettings().prettyPrint() == false)
    }
}
