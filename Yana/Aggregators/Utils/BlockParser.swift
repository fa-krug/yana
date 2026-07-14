import Foundation
import SwiftSoup

/// Converts the aggregation pipeline's already-sanitized article HTML into a closed `[Block]`
/// model for native rendering. This is the single HTML→blocks conversion point, run at import time
/// (in `ArticleUpsert`) and by the one-time `BlockMigration` sweep for existing articles — never on
/// the reader's render path.
///
/// The walk maps known tags to blocks and **drops** everything else (tables, forms, leftover
/// chrome): unknown wrappers are recursed into for any known blocks they contain, then discarded.
/// It runs on the HTML produced after `EmbedRewriter` + `HTMLUtils.finishSanitization`, so images
/// are already `yana-img://` refs, classes are stashed in `data-sanitized-class`, and video embeds
/// are normalized into recognizable facades.
enum BlockParser {

    // MARK: - Entry points

    /// Parse sanitized article HTML into blocks. `baseURL` (the article URL) resolves any relative
    /// link `href`s to absolute URLs so native taps open the right page.
    static func blocks(fromHTML html: String, baseURL: URL? = nil) -> [Block] {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let doc = try? SwiftSoup.parse(html) else {
            return []
        }
        let body = doc.body() ?? doc
        return convert(body, baseURL: baseURL)
    }

    /// Flatten blocks to visible plain text — the search and speech surface stored on
    /// `Article.plainText`. Sections are separated by blank lines.
    static func plainText(_ blocks: [Block]) -> String {
        var parts: [String] = []
        func runsText(_ runs: [InlineRun]) -> String { runs.map(\.text).joined() }
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case .paragraph(let runs): parts.append(runsText(runs))
                case .heading(_, let runs): parts.append(runsText(runs))
                case .list(_, let items): for item in items { walk(item) }
                case .blockquote(let inner): walk(inner)
                case .image(_, let caption):
                    let c = runsText(caption)
                    if !c.isEmpty { parts.append(c) }
                case .embed(let embed): if let t = embed.title { parts.append(t) }
                case .codeBlock(let text, _): parts.append(text)
                case .divider: break
                }
            }
        }
        walk(blocks)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Block walk

    /// Tags whose content is purely inline and is therefore buffered into the surrounding paragraph.
    private static let inlineTags: Set<String> = [
        "a", "b", "strong", "i", "em", "code", "span", "mark", "u", "s", "strike", "del",
        "sub", "sup", "small", "abbr", "cite", "q", "time", "label", "font", "ins", "var", "kbd",
    ]

    /// Tags dropped wholesale (not recursed) — they never map to a block and recursing would surface
    /// noise (table cells as stray paragraphs, etc.).
    private static let droppedTags: Set<String> = [
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "form", "input", "button", "select",
        "textarea", "script", "style", "noscript", "iframe", "audio", "svg", "canvas",
    ]

    private static func convert(_ container: Element, baseURL: URL?) -> [Block] {
        var blocks: [Block] = []
        var inline: [InlineRun] = []

        func flush() {
            let runs = trimmed(inline)
            if !runs.isEmpty { blocks.append(.paragraph(runs)) }
            inline = []
        }

        for node in container.getChildNodes() {
            if let textNode = node as? TextNode {
                let text = textNode.text()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inline.append(InlineRun(text: text))
                } else if !inline.isEmpty {
                    inline.append(InlineRun(text: " "))
                }
                continue
            }
            guard let element = node as? Element else { continue }
            let tag = element.tagName().lowercased()

            if droppedTags.contains(tag) { continue }

            if inlineTags.contains(tag) {
                if tag == "br" { inline.append(InlineRun(text: "\n")) }
                inline.append(contentsOf: inlineRuns(element, baseURL: baseURL))
                continue
            }

            switch tag {
            case "br":
                inline.append(InlineRun(text: "\n"))
            case "p":
                flush()
                let runs = trimmed(inlineRuns(element, baseURL: baseURL))
                if !runs.isEmpty { blocks.append(.paragraph(runs)) }
                // `inlineRuns` drops images (they can't live inside a text run), so a paragraph
                // that wraps media — Reddit emits Giphy, gallery, and inline images as
                // `<p><img></p>` — would otherwise vanish. Split any images out as their own
                // image blocks after the text (a pure-image `<p>` yields just the image).
                for img in (try? element.select("img").array()) ?? [] {
                    if let image = imageBlock(img) { blocks.append(image) }
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                let level = Int(String(tag.dropFirst())) ?? 1
                let runs = trimmed(inlineRuns(element, baseURL: baseURL))
                if !runs.isEmpty { blocks.append(.heading(level: min(max(level, 1), 6), runs: runs)) }
            case "ul", "ol":
                flush()
                blocks.append(listBlock(element, ordered: tag == "ol", baseURL: baseURL))
            case "blockquote":
                flush()
                if let embed = tweetEmbed(element, baseURL: baseURL) {
                    blocks.append(.embed(embed))
                } else {
                    let inner = convert(element, baseURL: baseURL)
                    if !inner.isEmpty { blocks.append(.blockquote(inner)) }
                }
            case "pre":
                flush()
                let text = (try? element.text()) ?? ""
                if !text.isEmpty { blocks.append(.codeBlock(text: text, language: nil)) }
            case "hr":
                flush()
                blocks.append(.divider)
            case "img":
                flush()
                if let image = imageBlock(element) { blocks.append(image) }
            case "video":
                flush()
                if let embed = videoEmbed(element) { blocks.append(.embed(embed)) }
            case "figure":
                flush()
                blocks.append(contentsOf: figureBlocks(element, baseURL: baseURL))
            default:
                // Unknown wrapper (div/section/header/footer/article/aside/main/…): an embed facade
                // becomes an embed; otherwise recurse for any known blocks inside and drop the wrapper.
                flush()
                if let embed = embedFacade(element) {
                    blocks.append(.embed(embed))
                } else {
                    blocks.append(contentsOf: convert(element, baseURL: baseURL))
                }
            }
        }

        flush()
        return blocks
    }

    private static func listBlock(_ element: Element, ordered: Bool, baseURL: URL?) -> Block {
        var items: [[Block]] = []
        for li in element.children().array() where li.tagName().lowercased() == "li" {
            let blocks = convert(li, baseURL: baseURL)
            items.append(blocks)
        }
        return .list(ordered: ordered, items: items)
    }

    private static func figureBlocks(_ element: Element, baseURL: URL?) -> [Block] {
        if let img = firstElement(in: element, "img") {
            let caption = firstElement(in: element, "figcaption")
                .map { inlineRuns($0, baseURL: baseURL) } ?? []
            if let block = imageBlock(img, caption: trimmed(caption)) { return [block] }
        }
        return convert(element, baseURL: baseURL)
    }

    /// The first descendant matching `selector`, or nil — a single-optional wrapper over SwiftSoup's
    /// throwing `select` so call sites avoid double optionals.
    private static func firstElement(in element: Element, _ selector: String) -> Element? {
        (try? element.select(selector))?.first()
    }

    private static func imageBlock(_ img: Element, caption: [InlineRun] = []) -> Block? {
        guard let src = try? img.attr("src"), !src.isEmpty else { return nil }
        return .image(ref: src, caption: caption)
    }

    /// A Reddit-hosted / Tagesschau `<video>` → a `.video` embed. The stream URL comes from the
    /// first `<source src>` (else the element's own `src`); the `poster` attribute — already
    /// localized to a `yana-img://` ref by the aggregator — is the card thumbnail. Returns nil when
    /// there is no playable source.
    private static func videoEmbed(_ element: Element) -> Embed? {
        let src: String? = {
            if let source = firstElement(in: element, "source"),
               let s = try? source.attr("src"), !s.isEmpty { return s }
            if let s = try? element.attr("src"), !s.isEmpty { return s }
            return nil
        }()
        guard let src, !src.isEmpty else { return nil }
        let poster = (try? element.attr("poster")).flatMap { $0.isEmpty ? nil : $0 }
        return Embed(provider: .video, thumbnailRef: poster, externalURL: src, title: nil)
    }

    // MARK: - Inline runs

    private static func inlineRuns(
        _ element: Element, baseURL: URL?, base: InlineStyle = [], link: String? = nil
    ) -> [InlineRun] {
        var runs: [InlineRun] = []
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                let text = textNode.text()
                if !text.isEmpty { runs.append(InlineRun(text: text, styles: base, link: link)) }
                continue
            }
            guard let child = node as? Element else { continue }
            let tag = child.tagName().lowercased()
            if droppedTags.contains(tag) { continue }
            if tag == "br" {
                runs.append(InlineRun(text: "\n", styles: base, link: link))
                continue
            }
            if tag == "img" {
                // Images can't live inside a text run; skip here. The block walk re-extracts them
                // as standalone image blocks (see the `<p>`/`figure` cases in `convert`).
                continue
            }
            if tag == "video" {
                // A `<video>` is a block-level media embed handled in `convert`; skip it here so its
                // plain-text fallback ("Your browser does not support…") never leaks into a run.
                continue
            }

            var style = base
            var resolvedLink = link
            switch tag {
            case "b", "strong": style.insert(.bold)
            case "i", "em", "cite", "var": style.insert(.italic)
            case "code", "kbd": style.insert(.code)
            case "s", "strike", "del": style.insert(.strikethrough)
            case "a":
                if let href = try? child.attr("href"), !href.isEmpty {
                    resolvedLink = resolveURL(href, baseURL: baseURL)
                }
            default: break
            }
            runs.append(contentsOf: inlineRuns(child, baseURL: baseURL, base: style, link: resolvedLink))
        }
        return runs
    }

    /// Trim leading/trailing whitespace runs and drop empties so paragraphs don't carry stray space.
    private static func trimmed(_ runs: [InlineRun]) -> [InlineRun] {
        var result = runs.filter { !$0.text.isEmpty }
        while let first = result.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeFirst()
        }
        while let last = result.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeLast()
        }
        return result
    }

    // MARK: - Embeds

    /// Recognize the YouTube/Dailymotion click-to-play facades `EmbedRewriter` emits (their class is
    /// stashed in `data-sanitized-class` by the sanitizer) and turn them into poster embeds. The
    /// video id is read from the player markup stashed in the facade's `data-embed` attribute; the
    /// poster `<img>` (already localized to `yana-img://`) is the thumbnail.
    private static func embedFacade(_ element: Element) -> Embed? {
        let cls = ((try? element.attr("data-sanitized-class")) ?? "")
        let isYouTube = cls.contains("youtube-embed-container")
        let isDailymotion = cls.contains("dailymotion-embed-container")
        guard isYouTube || isDailymotion else { return nil }

        let thumbnail = firstElement(in: element, "img")
            .flatMap { try? $0.attr("src") }
            .flatMap { $0.isEmpty ? nil : $0 }
        let embedMarkup = firstElement(in: element, "[data-embed]")
            .flatMap { try? $0.attr("data-embed") } ?? ""

        if isYouTube, let id = firstMatch(in: embedMarkup, pattern: #"embed/([A-Za-z0-9_-]{6,})"#) {
            return Embed(provider: .youtube, thumbnailRef: thumbnail,
                         externalURL: "https://www.youtube.com/watch?v=\(id)", title: nil)
        }
        if isDailymotion, let id = firstMatch(in: embedMarkup, pattern: #"video=([A-Za-z0-9]+)"#) {
            return Embed(provider: .dailymotion, thumbnailRef: thumbnail,
                         externalURL: "https://www.dailymotion.com/video/\(id)", title: nil)
        }
        return nil
    }

    /// A tweet/X embed: `EmbedRewriter.tweetEmbedHTML` renders a blockquote carrying a "View on X"
    /// link. Detect a blockquote linking to twitter/x and render it as a tappable text card.
    private static func tweetEmbed(_ element: Element, baseURL: URL?) -> Embed? {
        guard let links = try? element.select("a") else { return nil }
        for anchor in links.array() {
            guard let href = try? anchor.attr("href"),
                  let host = URL(string: href)?.host?.lowercased() else { continue }
            if host.contains("twitter.com") || host == "x.com" || host.hasSuffix(".x.com")
                || host.contains("fxtwitter.com") {
                let title = (try? element.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Embed(provider: .tweet, thumbnailRef: nil, externalURL: href,
                             title: (title?.isEmpty == false) ? title : nil)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func resolveURL(_ href: String, baseURL: URL?) -> String {
        if let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL {
            return resolved.absoluteString
        }
        return href
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}
