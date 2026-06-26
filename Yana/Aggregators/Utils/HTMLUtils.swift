import Foundation
import SwiftSoup

/// SwiftSoup-backed HTML utilities mirroring the server's html_cleaner / content_extractor.
enum HTMLUtils {
    static func parse(_ html: String) throws -> Document { try SwiftSoup.parse(html) }

    static func bodyHTML(_ doc: Document) throws -> String { try doc.body()?.html() ?? doc.html() }

    static func removeComments(_ doc: Document) throws {
        // Single recursive walk collecting Comment nodes, then remove them — avoids the
        // O(n^2) getAllElements()-then-children pass.
        var comments: [Node] = []
        func walk(_ node: Node) {
            for child in node.getChildNodes() {
                if child is Comment { comments.append(child) } else { walk(child) }
            }
        }
        walk(doc)
        for c in comments { try c.remove() }
    }

    static func sanitizeClassNames(_ doc: Document) throws {
        for el in try doc.getAllElements() where el.hasAttr("class") {
            let value = try el.attr("class")
            try el.removeAttr("class")
            try el.attr("data-sanitized-class", value)
        }
    }

    static func removeEmptyElements(_ doc: Document, tags: [String]) throws {
        for tag in tags {
            for el in try doc.select(tag) {
                // Preserve intentionally-empty decorative elements (e.g. the CSS-drawn play button
                // on a YouTube/Dailymotion facade), which mark themselves aria-hidden.
                if (try? el.attr("aria-hidden")) == "true" { continue }
                let text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let hasMedia = !(try el.select("img, iframe, video").isEmpty())
                if text.isEmpty && !hasMedia { try el.remove() }
            }
        }
    }

    // MARK: - Sanitization

    /// Tags that never render usefully in the reader and are dropped from every article body:
    /// scripts/styles execute or fight the theme, `noscript` is dead weight, and non-YouTube
    /// `iframe`s are trackers/ads. Run *after* `EmbedRewriter` so the YouTube embeds it normalizes
    /// (to `youtube-nocookie.com`) are recognized and kept.
    static func removeUnsafeTags(_ doc: Document) throws {
        for el in try doc.select("script, style, noscript") { try el.remove() }
        for el in try doc.select("iframe") {
            let src = try el.attr("src").lowercased()
            let isYouTube = src.contains("youtube.com") || src.contains("youtu.be")
                || src.contains("youtube-nocookie.com")
            if !isYouTube { try el.remove() }
        }
    }

    /// Strip inline event handlers (`onclick`, `onerror`, …) and `javascript:`/`vbscript:` URLs from
    /// `href`/`src`, so nothing executes when the body is rendered with JavaScript enabled.
    static func removeUnsafeAttributes(_ doc: Document) throws {
        for el in try doc.getAllElements() {
            guard let attrs = el.getAttributes() else { continue }
            for attr in attrs.asList() {
                let key = attr.getKey()
                let lower = key.lowercased()
                if lower.hasPrefix("on") {
                    try el.removeAttr(key)
                } else if lower == "href" || lower == "src" {
                    let value = attr.getValue().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if value.hasPrefix("javascript:") || value.hasPrefix("vbscript:") {
                        try el.removeAttr(key)
                    }
                }
            }
        }
    }

    /// Drop presentational `style` attributes so the theme's CSS fully governs appearance.
    static func removeInlineStyles(_ doc: Document) throws {
        for el in try doc.select("[style]") { try el.removeAttr("style") }
    }

    /// Remove 1×1 (or zero-size) tracking pixels. Call *before* image download so they are neither
    /// fetched nor cached.
    static func removeTrackingPixels(_ doc: Document) throws {
        for img in try doc.select("img") {
            let w = try img.attr("width").trimmingCharacters(in: .whitespaces)
            let h = try img.attr("height").trimmingCharacters(in: .whitespaces)
            if w == "0" || w == "1" || h == "0" || h == "1" { try img.remove() }
        }
    }

    /// Serialize without SwiftSoup's pretty-print indentation so the stored body is compact (smaller
    /// payload for the reader's `loadHTMLString`, less the WebView must parse).
    static func compact(_ doc: Document) { doc.outputSettings().prettyPrint(pretty: false) }

    /// Shared sanitization tail run after images are localized: neutralize handlers/URLs, strip
    /// inline styles, sanitize class names, drop comments and empty paragraphs/spans, and compact.
    /// Centralized so every aggregator's content pipeline stays consistent.
    static func finishSanitization(_ doc: Document) throws {
        try removeUnsafeAttributes(doc)
        try removeInlineStyles(doc)
        try sanitizeClassNames(doc)
        try removeComments(doc)
        try removeEmptyElements(doc, tags: ["p", "span"])
        compact(doc)
    }

    static func removeImageByURL(_ doc: Document, url: String) throws {
        guard !url.isEmpty, !url.hasPrefix("data:") else { return }
        let targetBase = baseFilename(url)
        let targetFile = (url as NSString).lastPathComponent
        for img in try doc.select("img") {
            var src = try firstNonEmpty(img, ["src", "data-src", "data-lazy-src"])
            if src == nil || src!.hasPrefix("data:") {
                src = largestSrcsetURL(try img.attr("srcset"))
            }
            guard let src, !src.hasPrefix("data:") else { continue }
            let file = (src as NSString).lastPathComponent
            if src == url || (file == targetFile && file.count > 3) || (baseFilename(src) == targetBase && targetBase.count > 3) {
                try img.remove()
                return
            }
        }
    }

    static func extractMainContent(_ html: String, selector: String, removeSelectors: [String]) throws -> String {
        let doc = try parse(html)
        let content: Element = (try? doc.select(selector).first()) ?? doc.body() ?? doc
        for sel in removeSelectors {
            for el in try content.select(sel) { try el.remove() }
        }
        return try content.html()
    }

    // MARK: - Filename helpers (mirror server _get_base_filename)

    private static let dimensionSuffix = try? NSRegularExpression(pattern: #"(?:-\d+x\d+|-\d+)+$"#)
    private static let hashSuffix = try? NSRegularExpression(pattern: #"-[a-zA-Z0-9]{3,6}$"#)

    private static func baseFilename(_ url: String) -> String {
        var name = (url as NSString).lastPathComponent
        if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
        name = strip(dimensionSuffix, from: name)
        name = strip(hashSuffix, from: name)
        return name
    }

    private static func strip(_ regex: NSRegularExpression?, from s: String) -> String {
        guard let regex else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private static func firstNonEmpty(_ el: Element, _ attrs: [String]) throws -> String? {
        for a in attrs {
            let v = try el.attr(a)
            if !v.isEmpty { return v }
        }
        return nil
    }
}
