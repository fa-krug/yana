import Foundation

/// A closed, typed article-body block. Article bodies are stored as a JSON-encoded `[Block]`
/// (on `Article.blockData`) and rendered natively in SwiftUI — there is never an inline WebView in
/// the body. Any source node that does not map to one of these cases is **dropped** during
/// conversion (see `BlockParser`); tables, forms, scripts and unmodelled chrome fall through to
/// nothing.
enum Block: Codable, Sendable, Equatable {
    /// A run of styled inline text (the common body paragraph).
    case paragraph([InlineRun])
    /// A heading; `level` is clamped to 1…6.
    case heading(level: Int, runs: [InlineRun])
    /// An ordered/unordered list. Each item is itself a block sequence (so a list item can hold
    /// paragraphs, nested lists, etc.).
    case list(ordered: Bool, items: [[Block]])
    /// A blockquote wrapping further blocks.
    case blockquote([Block])
    /// An image referenced by a `yana-img://<hash>` ref (resolved against the local `ImageStore`),
    /// or a remote URL fallback, with an optional caption.
    case image(ref: String, caption: [InlineRun])
    /// A media embed rendered as a tappable poster/text card that opens externally.
    case embed(Embed)
    /// A preformatted code block.
    case codeBlock(text: String, language: String?)
    /// A horizontal rule.
    case divider
}

/// Inline text styles, combinable (bold + italic, etc.).
struct InlineStyle: OptionSet, Codable, Sendable, Equatable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let bold = InlineStyle(rawValue: 1 << 0)
    static let italic = InlineStyle(rawValue: 1 << 1)
    static let code = InlineStyle(rawValue: 1 << 2)
    static let strikethrough = InlineStyle(rawValue: 1 << 3)
}

/// A styled span of text inside a paragraph/heading. `link` (when present) is an absolute URL that
/// a tap opens externally via `ReaderLinkPolicy`.
struct InlineRun: Codable, Sendable, Equatable {
    var text: String
    var styles: InlineStyle
    var link: String?

    init(text: String, styles: InlineStyle = [], link: String? = nil) {
        self.text = text
        self.styles = styles
        self.link = link
    }
}

/// A media embed. Rendered as a poster card (video) or a text card (tweet); a tap opens
/// `externalURL` in the system browser / in-app Safari. No inline iframe playback.
struct Embed: Codable, Sendable, Equatable {
    enum Provider: String, Codable, Sendable {
        case youtube, dailymotion, tweet, generic
    }

    var provider: Provider
    /// `yana-img://<hash>` (cached poster) or a remote URL, else `nil` (text card).
    var thumbnailRef: String?
    /// Where a tap navigates.
    var externalURL: String
    /// Optional label (video title, tweet author).
    var title: String?
}
