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

/// A media embed. Rendered as a poster card (video) or a text card (tweet); a tap plays the video
/// in-app or opens `externalURL` in the system browser / in-app Safari.
struct Embed: Codable, Sendable, Equatable {
    enum Provider: String, Codable, Sendable {
        /// Providers played inline via their privacy-mode iframe player.
        case youtube, dailymotion
        /// A direct video stream (HLS `.m3u8` or MP4), e.g. a Reddit `v.redd.it` post. `externalURL`
        /// is the stream URL, played inline via `AVPlayer`; `thumbnailRef` is the cached poster.
        case video
        /// Rendered as a text card that opens `externalURL` externally.
        case tweet, generic
    }

    var provider: Provider
    /// `yana-img://<hash>` (cached poster) or a remote URL, else `nil` (text card).
    var thumbnailRef: String?
    /// Where a tap navigates, or — for `.video` — the direct stream URL played in-app.
    var externalURL: String
    /// Optional label (video title, tweet author).
    var title: String?
}

extension Block {
    /// Every `ImageStore` content hash reachable from `blocks` -- `.image` refs and embed
    /// `thumbnailRef`s, recursing into lists/blockquotes since those nest further blocks. A
    /// remote-URL ref (not a `yana-img://` ref) yields no hash, since there's nothing for it in
    /// `ImageStore` to prefetch or prune. Shared by `SyncEngine` (prefetching every referenced
    /// image during sync, not just the lead image on-demand) and `SyncWriter`
    /// (`referencedImageHashes`, so a since-deleted article's images can be told apart from ones
    /// still in use).
    static func imageHashes(in blocks: [Block]) -> Set<String> {
        var hashes = Set<String>()
        func visit(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .image(ref, _):
                    if let hash = imageHash(fromRef: ref) { hashes.insert(hash) }
                case let .list(_, items):
                    items.forEach(visit)
                case let .blockquote(children):
                    visit(children)
                case let .embed(embed):
                    if let ref = embed.thumbnailRef, let hash = imageHash(fromRef: ref) {
                        hashes.insert(hash)
                    }
                case .paragraph, .heading, .codeBlock, .divider:
                    break
                }
            }
        }
        visit(blocks)
        return hashes
    }

    private static func imageHash(fromRef ref: String) -> String? {
        let prefix = "\(ReaderWeb.imageScheme)://"
        guard ref.hasPrefix(prefix) else { return nil }
        return String(ref.dropFirst(prefix.count))
    }
}
