import Foundation

/// A closed, typed article-body block. Article bodies are stored as a JSON-encoded `[Block]`
/// (on `Article.blockData`) and rendered natively in SwiftUI — there is never an inline WebView in
/// the body. Blocks arrive already parsed from the server (`BlockWireDecoding`), which is where any
/// unmodelled source markup (tables, forms, scripts, chrome) is dropped; the client never parses
/// markup itself.
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
    /// An AI summary of the article, wrapping further blocks so a multi-paragraph summary stays
    /// inside the one block instead of pushing the article down the document. This is the *only*
    /// place a summary lives: the server emits it for feeds with "Summarize" enabled, and the
    /// reader's own summarize action writes into the same slot (`Block.settingSummary`), so there
    /// is one source of truth and never two stacked summary cards.
    case summary([Block])
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
                case let .summary(children):
                    // Summaries are prose today, so this is defensive -- but a summary is a block
                    // wrapper like any other, and an image inside one still needs its bytes kept.
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

// MARK: - The summary slot

/// The document's fixed order for a summary, shared by everything that reads or writes one so they
/// cannot drift apart: the lead media first (when there is one), the summary second, the article
/// after them. The server guarantees this shape for the summaries it emits; these helpers put a
/// locally-generated summary in the same place, and are the only code that decides where that is.
///
/// A summary is matched and placed at the **top level** only. The server never nests one, and
/// treating a summary buried in a list item as the article's summary would be wrong -- the
/// renderer still handles that case, it just isn't this slot.
extension Block {
    /// Whether `blocks` already carries a top-level summary.
    static func containsSummary(_ blocks: [Block]) -> Bool {
        blocks.contains(where: isSummary)
    }

    /// The contents of the first top-level summary in `blocks`, or `nil` when there is none.
    static func summaryContents(of blocks: [Block]) -> [Block]? {
        for block in blocks {
            if case let .summary(inner) = block { return inner }
        }
        return nil
    }

    private static func isSummary(_ block: Block) -> Bool {
        if case .summary = block { return true }
        return false
    }

    /// `blocks` without any top-level summary -- the article's own text. Fed to the summarizer so
    /// re-summarizing an article that already carries a summary summarizes the *article* rather
    /// than folding its own previous summary back into the input.
    static func removingSummaries(from blocks: [Block]) -> [Block] {
        blocks.filter { !isSummary($0) }
    }

    /// `blocks` with `contents` as its summary: replacing an existing top-level summary in place,
    /// or inserted at the summary slot when there is none.
    static func settingSummary(_ contents: [Block], in blocks: [Block]) -> [Block] {
        if let existing = blocks.firstIndex(where: isSummary) {
            var result = blocks
            result[existing] = .summary(contents)
            return result
        }
        var result = blocks
        result.insert(.summary(contents), at: summarySlot(in: blocks))
        return result
    }

    /// `incoming` with `previous`'s summary carried over, when `incoming` has none of its own.
    ///
    /// A content re-fetch replaces an article's blocks wholesale (`SyncWriter.applyContent`), which
    /// would otherwise silently destroy a summary the user generated on this device -- the summary
    /// is body content now, not a column alongside it. A server-supplied summary always wins; this
    /// only fills the gap when the server sends a document without one.
    static func preservingSummary(from previous: [Block], in incoming: [Block]) -> [Block] {
        guard !containsSummary(incoming), let carried = summaryContents(of: previous) else {
            return incoming
        }
        return settingSummary(carried, in: incoming)
    }

    /// Where a summary goes in a document that has none: after the lead media when the document
    /// opens with one, first otherwise. The lead media has no block kind of its own -- it is the
    /// ordinary `image`/`embed` block it always was, identified purely by leading the document
    /// (the same rule `ArticleBlockView.leadImageRef` and `Article.leadImageRef` hoist on).
    private static func summarySlot(in blocks: [Block]) -> Int {
        guard let first = blocks.first else { return 0 }
        switch first {
        case .image, .embed: return 1
        default: return 0
        }
    }
}
