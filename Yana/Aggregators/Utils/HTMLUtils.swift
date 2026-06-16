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
                let text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let hasMedia = !(try el.select("img, iframe, video").isEmpty())
                if text.isEmpty && !hasMedia { try el.remove() }
            }
        }
    }

    static func removeImageByURL(_ doc: Document, url: String) throws {
        guard !url.isEmpty, !url.hasPrefix("data:") else { return }
        let targetBase = baseFilename(url)
        let targetFile = (url as NSString).lastPathComponent
        for img in try doc.select("img") {
            let src = try firstNonEmpty(img, ["src", "data-src", "data-lazy-src"])
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
