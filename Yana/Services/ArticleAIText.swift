import Foundation

/// Pure, `Sendable` text helpers used by `AppleIntelligenceChunkedSummarizer`: the content-size cap
/// and the summarize-task instruction string.
///
/// A `stripChrome(_:)` helper used to live here too, removing `header`/`footer`/`nav`/`script`/
/// `style` from article HTML via SwiftSoup. Its only caller feeds it `Article.plainText`, so it was
/// parsing plain text as HTML and handing back that text wrapped in `<html><head></head><body>…`
/// boilerplate — chrome the model then had to read past. Article bodies have not been HTML on this
/// client since blocks arrived pre-parsed from the server, so it is gone.
enum ArticleAIText {
    /// Upper bound on characters of article text sent to any model.
    static let maxContentChars = 50_000

    /// Truncate to the character budget (no-op when already within it).
    static func cap(_ text: String) -> String {
        text.count <= maxContentChars ? text : String(text.prefix(maxContentChars))
    }

    static let summarizeInstruction =
        "Summarize the article content concisely."
}
