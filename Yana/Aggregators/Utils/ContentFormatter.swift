import Foundation

/// Wraps article content: optional header, content section, optional comments section.
/// The source link is exposed via the reader's toolbar rather than appended to the body.
enum ContentFormatter {
    /// Escape text for safe inclusion in HTML element text and double-quoted attributes.
    /// Order matters: `&` first so later replacements aren't double-escaped.
    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func format(content: String, title: String, url: String, headerHTML: String?, commentsHTML: String?) -> String {
        var parts: [String] = []
        if let headerHTML, !headerHTML.isEmpty { parts.append(headerHTML) }
        parts.append("<section data-sanitized-class=\"article-content\">\(content)</section>")
        if let commentsHTML, !commentsHTML.isEmpty {
            parts.append("<section data-sanitized-class=\"article-comments\">\(commentsHTML)</section>")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Standard header markup for an already-cached header image (referenced via yana-img://).
    static func headerImageHTML(src: String, alt: String, captionHTML: String? = nil) -> String {
        let safeAlt = escapeHTML(alt)
        var html = "<header style=\"margin-bottom: 1.5em; text-align: center;\">"
        html += "<img src=\"\(src)\" alt=\"\(safeAlt)\" style=\"max-width: 100%; height: auto; border-radius: 8px;\">"
        if let captionHTML { html += captionHTML }
        html += "</header>"
        return html
    }
}
