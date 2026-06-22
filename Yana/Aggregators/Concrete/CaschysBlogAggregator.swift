import Foundation
import SwiftSoup

/// Caschy's Blog (stadt-bremerhaven.de). Ports core/aggregators/caschys_blog/aggregator.py:
/// `.entry-inner` content, `.aawp*` removal, ad/recap skips, iframe whitelist, relative-URL
/// resolution, first-image dedup. Single feed.
class CaschysBlogAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://stadt-bremerhaven.de/feed/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://stadt-bremerhaven.de/feed/", "Caschy's Blog (Main Feed)"),
    ]

    var caschyOptions: CaschysBlogOptions {
        if case .caschysBlog(let o) = config.options { return o }
        return CaschysBlogOptions()
    }

    override var contentSelector: String { ".entry-inner" }

    override var selectorsToRemove: [String] {
        [".aawp", ".aawp-disclaimer", "script", "style", "noscript", "svg"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    override func shouldInclude(_ article: AggregatedArticle) -> Bool {
        let title = article.title
        if caschyOptions.skipAds, title.contains("(Anzeige)") { return false }
        if title.contains("Immer wieder sonntags KW") { return false }
        return true
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        let base = URL(string: article.url)

        // Remove WordPress self-embed promo blocks (e.g. "Audible 3 Monate kostenlos nutzen",
        // "Amazon Music Unlimited: Vier Monate gratis für Prime-Mitglieder"). These render as a
        // `.wp-embedded-content` blockquote + iframe, usually wrapped in a `.video-container`.
        // The iframe whitelist below would strip only the iframe, leaving the visible link behind.
        if caschyOptions.skipAds {
            for embed in try doc.select(".wp-embedded-content") {
                if let container = embed.parent(), container.hasClass("video-container") {
                    try container.remove()
                } else {
                    try embed.remove()
                }
            }
        }

        // Iframe whitelist: keep only YouTube + Twitter/X; remove the rest.
        for iframe in try doc.select("iframe") {
            let src = try iframe.attr("src")
            let isYouTube = src.contains("youtube.com") || src.contains("youtu.be")
            let isTwitter = src.contains("twitter.com") || src.contains("x.com")
            if src.isEmpty || !(isYouTube || isTwitter) { try iframe.remove() }
        }

        // Resolve relative URLs for images and links.
        for img in try doc.select("img") {
            let src = try img.attr("src")
            if !src.isEmpty, !src.hasPrefix("http://"), !src.hasPrefix("https://"), !src.hasPrefix("data:") {
                if let abs = URL(string: src, relativeTo: base)?.absoluteString { try img.attr("src", abs) }
            }
        }
        for a in try doc.select("a") {
            let href = try a.attr("href")
            if !href.isEmpty, !["http://", "https://", "mailto:", "tel:", "#"].contains(where: { href.hasPrefix($0) }) {
                if let abs = URL(string: href, relativeTo: base)?.absoluteString { try a.attr("href", abs) }
            }
        }

        // Dedup the first image when there is a header image.
        if header != nil { try removeFirstImage(doc) }

        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: base)
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }

    /// Remove a leading image (direct, in a paragraph, or inside a link) — duplicate of the header.
    private func removeFirstImage(_ doc: Document) throws {
        guard let body = doc.body() else { return }
        for element in body.children().array() {
            switch element.tagName() {
            case "img":
                try element.remove(); return
            case "p":
                for child in element.children().array() {
                    if child.tagName() == "img" { try child.remove(); return }
                    if child.tagName() == "a", let img = try child.select("img").first() {
                        _ = img; try child.remove(); return
                    }
                    if child.tagName() == "br" { continue }
                    return
                }
                return
            default:
                return  // only inspect the first significant element
            }
        }
    }
}
