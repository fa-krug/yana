import Foundation
import SwiftSoup

/// Reduces a fetched page/response to a compact, token-cheap sample for the AI script generator,
/// so the model writes selectors/field mappings against the real shape without blowing the
/// context window. HTML → a de-noised skeleton (tags + id/class kept, scripts/styles dropped);
/// JSON → a pretty-printed, truncated shape; anything else → trimmed text.
enum ScriptContextReducer {
    /// Tags whose contents are noise for selector authoring.
    private static let noiseTags = ["script", "style", "svg", "noscript", "link", "meta"]

    static func reduce(body: String, contentType: String?, maxChars: Int = 6000) -> String {
        if looksLikeJSON(body: body, contentType: contentType) {
            return jsonShape(body, maxChars: maxChars)
        }
        return htmlSkeleton(body, maxChars: maxChars)
    }

    static func looksLikeJSON(body: String, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("json") { return true }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    /// Drop noisy tags, collapse whitespace, and truncate — preserving the tag/class/id structure
    /// the model needs to write CSS selectors.
    static func htmlSkeleton(_ html: String, maxChars: Int) -> String {
        let reduced: String
        do {
            let doc = try SwiftSoup.parse(html)
            for tag in noiseTags {
                for element in try doc.select(tag).array() { try element.remove() }
            }
            reduced = try (doc.body()?.html() ?? doc.html())
        } catch {
            reduced = html
        }
        return truncate(collapseWhitespace(reduced), to: maxChars)
    }

    /// Pretty-print the JSON shape. For arrays, keep only the first two elements so the model sees
    /// the item shape without the whole payload.
    static func jsonShape(_ json: String, maxChars: Int) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return truncate(collapseWhitespace(json), to: maxChars)
        }
        let trimmed = trimForShape(object)
        guard let pretty = try? JSONSerialization.data(withJSONObject: trimmed,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return truncate(json, to: maxChars)
        }
        return truncate(text, to: maxChars)
    }

    /// Recursively cap arrays to their first two elements so a long list collapses to its shape.
    private static func trimForShape(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.prefix(2).map(trimForShape)
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues(trimForShape)
        }
        return value
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, to maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "\n…(truncated)"
    }
}
