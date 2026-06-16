import Foundation
import SwiftSoup

/// Base for fixed-source web comics: a hardcoded feed, single comic image per article,
/// optional alt/title caption, image localized via the shared pipeline. Header disabled.
class ComicAggregator: FullWebsiteAggregator, @unchecked Sendable {
    /// The hardcoded RSS feed for this comic.
    var feedURL: String { "" }
    /// CSS selector for the comic container.
    override var contentSelector: String { "body" }
    /// Whether to show alt text below the image (subclasses read their own options).
    var showAltText: Bool { true }

    override func fetchEntries() async throws -> [FeedEntry] {
        guard let url = URL(string: feedURL) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(url)
        return try FeedParser.parse(data).entries
    }

    override func validate() throws {}   // fixed source; no user identifier required

    /// Comics ignore the generic header element; they build content from the comic image.
    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        do {
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw
            let comicHTML = try buildComicHTML(pageHTML: raw, article: article)
            // Localize images + wrap. (rewriteImages downloads the comic image → yana-img://.)
            let doc = try HTMLUtils.parse(comicHTML)
            try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
            let body = try HTMLUtils.bodyHTML(doc)
            article.content = ContentFormatter.format(content: body, title: article.title, url: article.url,
                                                      headerHTML: nil, commentsHTML: nil)
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            throw AggregatorError.articleSkip(statusCode: 0)   // omit this comic, keep the rest of the batch
        } catch {
            throw AggregatorError.articleSkip(statusCode: 0)
        }
    }

    /// Subclasses override to locate the comic image(s) and produce the inner HTML.
    func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let extracted = try HTMLUtils.extractMainContent(pageHTML, selector: contentSelector, removeSelectors: [])
        return extracted
    }

    /// Shared caption markup (mirrors the server's italic caption).
    func captionHTML(_ text: String) -> String {
        guard showAltText, !text.isEmpty else { return "" }
        let safe = text.replacingOccurrences(of: "<", with: "&lt;")
        return "<p style=\"font-style: italic; margin-top: 1em; color: #666; text-align: center;\">\(safe)</p>"
    }
}

/// Cyanide & Happiness. Feed https://explosm.net/rss.xml; image src contains static.explosm.net.
class ExplosmAggregator: ComicAggregator, @unchecked Sendable {
    override var feedURL: String { "https://explosm.net/rss.xml" }
    override var contentSelector: String { "#comic" }
    override var showAltText: Bool {
        if case .explosm(let o) = config.options { return o.showAltText }
        return true
    }

    override func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let doc = try HTMLUtils.parse(pageHTML)
        let img = try doc.select("img").first { try $0.attr("src").contains("static.explosm.net") }
        guard let img, let src = try? img.attr("src") else { return "" }
        let alt = (try? img.attr("alt")) ?? ""
        return "<div style=\"text-align: center;\"><img src=\"\(src)\" alt=\"\(alt.replacingOccurrences(of: "\"", with: "&quot;"))\">\(captionHTML(alt))</div>"
    }
}

/// Dark Legacy Comics. Feed https://darklegacycomics.com/feed.xml; container #gallery;
/// images may be relative → resolved against the article URL by rewriteImages.
class DarkLegacyAggregator: ComicAggregator, @unchecked Sendable {
    override var feedURL: String { "https://darklegacycomics.com/feed.xml" }
    override var contentSelector: String { "#gallery" }
    override var showAltText: Bool {
        if case .darkLegacy(let o) = config.options { return o.showAltText }
        return true
    }

    override func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let doc = try HTMLUtils.parse(pageHTML)
        let gallery = try doc.select(contentSelector).first() ?? doc.body() ?? doc
        var html = "<div style=\"text-align: center;\">"
        for img in try gallery.select("img") {
            let src = try img.attr("src")
            guard !src.isEmpty else { continue }
            let alt = (try? img.attr("alt")) ?? ""
            // Leave src as-is (may be relative); rewriteImages resolves against baseURL.
            html += "<img src=\"\(src)\" alt=\"\(alt.replacingOccurrences(of: "\"", with: "&quot;"))\">\(captionHTML(alt))"
        }
        html += "</div>"
        return html
    }
}

/// Oglaf (adult). Feed https://www.oglaf.com/feeds/rss/; image #strip (fallback .content img);
/// the <img title> holds a second joke shown as caption. Images localized regardless of
/// convertToBase64 (decision 3).
class OglafAggregator: ComicAggregator, @unchecked Sendable {
    override var feedURL: String { "https://www.oglaf.com/feeds/rss/" }
    override var contentSelector: String { "div.content" }
    override var showAltText: Bool {
        if case .oglaf(let o) = config.options { return o.showAltText }
        return true
    }

    override func buildComicHTML(pageHTML: String, article: AggregatedArticle) throws -> String {
        let doc = try HTMLUtils.parse(pageHTML)
        let img = try doc.select("#strip").first()
            ?? doc.select(".content img, #content img, .comic img").first()
        guard let img else { return "" }
        var src = try img.attr("src")
        if src.hasPrefix("/") {
            src = "https://www.oglaf.com" + src
        } else if !src.hasPrefix("http") && !src.contains("media.oglaf.com") {
            src = "https://media.oglaf.com/comic/" + src
        }
        let joke = (try? img.attr("title")) ?? ""
        let alt = ((try? img.attr("alt")) ?? "").replacingOccurrences(of: "\"", with: "&quot;")
        return "<div style=\"text-align: center;\"><img src=\"\(src)\" alt=\"\(alt)\" "
            + "style=\"max-width: 100%; height: auto;\">\(captionHTML(joke))</div>"
    }
}
