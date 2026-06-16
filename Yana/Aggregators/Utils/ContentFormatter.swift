import Foundation

/// Wraps article content in the server's exact shape: optional header, content section,
/// optional comments section, source footer (content_formatter.py parity).
enum ContentFormatter {
    static func format(content: String, title: String, url: String, headerHTML: String?, commentsHTML: String?) -> String {
        var parts: [String] = []
        if let headerHTML, !headerHTML.isEmpty { parts.append(headerHTML) }
        parts.append("<section data-sanitized-class=\"article-content\">\(content)</section>")
        if let commentsHTML, !commentsHTML.isEmpty {
            parts.append("<section data-sanitized-class=\"article-comments\">\(commentsHTML)</section>")
        }
        let escapedURL = url.replacingOccurrences(of: "\"", with: "&quot;")
        parts.append("<footer><p>Source: <a href=\"\(escapedURL)\" target=\"_blank\" rel=\"noopener\">\(escapedURL)</a></p></footer>")
        return parts.joined(separator: "\n\n")
    }

    /// Standard header markup for an already-cached header image (referenced via yana-img://).
    static func headerImageHTML(src: String, alt: String, captionHTML: String? = nil) -> String {
        let safeAlt = alt.replacingOccurrences(of: "\"", with: "&quot;")
        var html = "<header style=\"margin-bottom: 1.5em; text-align: center;\">"
        html += "<img src=\"\(src)\" alt=\"\(safeAlt)\" style=\"max-width: 100%; height: auto; border-radius: 8px;\">"
        if let captionHTML { html += captionHTML }
        html += "</header>"
        return html
    }
}
