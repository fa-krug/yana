import Foundation
import SwiftSoup

/// Pure, `Sendable` text helpers used by `AppleIntelligenceChunkedSummarizer`: HTML chrome
/// stripping, the content-size cap, and the summarize-task instruction string.
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

    static let summarizeInstruction =
        "Summarize the article content concisely."
}
