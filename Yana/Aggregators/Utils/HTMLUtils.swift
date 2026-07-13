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

    /// Remove `<template>` elements. Template content is inert by the HTML spec — a browser never
    /// renders it, it exists only to be cloned by JavaScript — but SwiftSoup exposes its children as
    /// ordinary selectable DOM. Without this, a content selector like `article` matches the
    /// `<article>` teasers inside sites' client-side templates (e.g. Heise's `upscore-reco-template`
    /// recommendation boxes), leaking their raw `${intro}`/`${title}`/`${lead}` placeholders into the
    /// extracted body. Run before content extraction so nested templates never reach the reader.
    static func removeTemplates(_ doc: Document) throws {
        for el in try doc.select("template") { try el.remove() }
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
        try removeTemplates(doc)
        try removeUnsafeAttributes(doc)
        try removeInlineStyles(doc)
        try sanitizeClassNames(doc)
        try removeComments(doc)
        try removeEmptyElements(doc, tags: ["p", "span"])
        compact(doc)
    }

    /// Remove the body's copy of the hoisted header image, matched by exact URL, last path
    /// component, or normalized base filename. Returns `true` when an image was removed so callers
    /// can fall back to a structural removal (`removeLeadingLeadImage`) when the URL didn't match.
    @discardableResult
    static func removeImageByURL(_ doc: Document, url: String) throws -> Bool {
        guard !url.isEmpty, !url.hasPrefix("data:") else { return false }
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
                return true
            }
        }
        return false
    }

    /// Remove a leading byline/dateline element whose text is dominated by the article `author`
    /// (typically "date · author"). The reader renders author + date in its own chrome, so this
    /// masthead line is a duplicate. Only the leading masthead region is scanned — the walk stops at
    /// the first substantial prose paragraph — and only a short element containing the author is
    /// removed, so a paragraph that merely mentions the author is left alone. No-op when `author` is
    /// blank/too short to identify reliably.
    static func removeDuplicateByline(_ doc: Document, author: String) throws {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 3 else { return }
        let needle = name.lowercased()
        for el in try doc.select("p, div, span, address, time, li, h3, h4, h5, h6") {
            let text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 200 { break }   // reached prose; bylines sit above the article text
            if text.count <= name.count + 40, text.lowercased().contains(needle) {
                try el.remove()
                return
            }
        }
    }

    /// Fallback lead-image de-dup: remove the article's leading media — the first `<figure>` (or a
    /// standalone leading `<img>`) that appears before the first substantial prose paragraph. Used
    /// when `removeImageByURL` can't match the hoisted header image to its in-body copy because the
    /// page's og:image and body image are different derivatives of the same source (e.g. Golem).
    /// Returns `false` (removing nothing) when the first media element only appears after real prose,
    /// where it is a content image rather than the lead.
    @discardableResult
    static func removeLeadingLeadImage(_ doc: Document) throws -> Bool {
        for el in try doc.select("figure, img, p") {
            switch el.tagName() {
            case "p":
                let text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 200 { return false }   // prose precedes any lead media → keep images
            case "figure", "img":
                // A figure is hit before its child <img> (document order), so removing it drops both.
                try el.remove()
                return true
            default:
                break
            }
        }
        return false
    }

    static func extractMainContent(_ html: String, selector: String, removeSelectors: [String]) throws -> String {
        let doc = try parse(html)
        try removeTemplates(doc)
        let content: Element = (try? doc.select(selector).first()) ?? doc.body() ?? doc
        for sel in removeSelectors {
            for el in try content.select(sel) { try el.remove() }
        }
        return try content.html()
    }

    /// OR-union extraction: combine every element matching any of `contentSelectors` into one
    /// body (to gather content distributed across several containers), dropping matches nested
    /// inside another match so overlaps aren't duplicated. Falls back to `<body>` when nothing
    /// matches. Then removes every element matching any of `removeSelectors` from the result.
    static func extractMainContent(_ html: String, contentSelectors: [String], removeSelectors: [String]) throws -> String {
        let doc = try parse(html)
        try removeTemplates(doc)

        // Collect matches for every selector, preserving document order and de-duplicating the
        // same element matched by multiple selectors.
        var matched: [Element] = []
        var seen = Set<ObjectIdentifier>()
        for sel in contentSelectors where !sel.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let els = try? doc.select(sel) else { continue }
            for el in els where seen.insert(ObjectIdentifier(el)).inserted {
                matched.append(el)
            }
        }
        // Keep only outermost matches — an element contained in another match is already included.
        let roots = matched.filter { el in !matched.contains { $0 !== el && isDescendant(el, of: $0) } }

        let container = Element(SwiftSoup.Tag("div"), "")
        if roots.isEmpty {
            try container.append((doc.body() ?? doc).html())
        } else {
            // Move each outermost match into the container (the source doc is discarded after this).
            // roots are disjoint subtrees, so moving one never affects another.
            for el in roots { try container.appendChild(el) }
        }
        for sel in removeSelectors where !sel.trimmingCharacters(in: .whitespaces).isEmpty {
            for el in try container.select(sel) { try el.remove() }
        }
        return try container.html()
    }

    /// Remove a leading `<h1>`/`<h2>` whose text duplicates the article `title`. The reader renders
    /// the title itself as the masthead, so a repeated headline at the top of the extracted body is
    /// noise. Only the first heading in document order is considered, and it is removed when its text
    /// matches the title exactly (case/whitespace-insensitive) or one clearly contains the other, so
    /// a mid-article heading that merely shares wording is left alone.
    static func removeDuplicateTitleHeading(_ doc: Document, title: String) throws {
        let normTitle = normalizeHeadingText(title)
        guard !normTitle.isEmpty, let heading = try doc.select("h1, h2").first() else { return }
        let normHeading = normalizeHeadingText(try heading.text())
        guard !normHeading.isEmpty else { return }
        let contained = normHeading.count > 12 && normTitle.count > 12
            && (normHeading.contains(normTitle) || normTitle.contains(normHeading))
        if normHeading == normTitle || contained { try heading.remove() }
    }

    private static func normalizeHeadingText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// True when `node` is a (transitive) descendant of `ancestor`.
    private static func isDescendant(_ node: Element, of ancestor: Element) -> Bool {
        var parent = node.parent()
        while let p = parent {
            if p === ancestor { return true }
            parent = p.parent()
        }
        return false
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
