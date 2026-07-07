import Foundation
import SwiftSoup

/// Pure, `Sendable` text helpers shared by the HTTP `AIProcessor` and the on-device
/// `AppleIntelligenceProcessor`: HTML chrome stripping, the content-size cap, and the
/// server-parity per-task instruction strings. Single source of truth for both paths.
enum ArticleAIText {
    /// Upper bound on characters of article HTML sent to any model.
    static let maxContentChars = 50_000

    /// Truncate to the character budget (no-op when already within it).
    static func cap(_ html: String) -> String {
        html.count <= maxContentChars ? html : String(html.prefix(maxContentChars))
    }

    /// Remove header/footer/nav/script/style; return the sanitized document HTML.
    static func stripChrome(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        for tag in ["header", "footer", "nav", "script", "style"] {
            try doc.select(tag).remove()
        }
        return try doc.html()
    }

    /// The leading `<header>` block(s) that `stripChrome` removes — these carry the article's
    /// cached lead image. Returned as outer HTML so AI post-processing can re-attach the header
    /// to the model's output (which is generated from header-stripped input and would otherwise
    /// drop the lead image). Returns nil when the content has no `<header>`. Pure — no network.
    static func leadingHeaderHTML(_ html: String) throws -> String? {
        let doc = try SwiftSoup.parse(html)
        let headers = try doc.select("header").array()
        guard !headers.isEmpty else { return nil }
        return try headers.map { try $0.outerHtml() }.joined()
    }

    static let summarizeInstruction =
        "Summarize the article content concisely."

    static let improveWritingInstruction =
        "Rewrite the content to improve clarity, flow, and style. "
        + "IMPORTANT: Preserve the complete HTML structure including all tags. "
        + "Keep all links (<a> tags) exactly as they are - do not modify href attributes or remove any links. "
        + "Only improve the text content itself."

    static func translateInstruction(language: String) -> String {
        let targetLang = language.isEmpty ? "English" : language
        return "Translate the title and content to \(targetLang). "
            + "Translate the ENTIRE content, including any reader comments and any text "
            + "quoted inside <blockquote> elements. The comment/discussion section must be "
            + "translated too — do not leave it in the original language. "
            + "IMPORTANT: Do NOT translate link labels (the text inside <a> tags). "
            + "Keep link text in the original language. Translate every other piece of "
            + "human-readable text, including comment bodies."
    }
}
