import Foundation
import SwiftSoup

/// Heise.de German tech news. Ports core/aggregators/heise/aggregator.py:
/// `seite=all` multi-page fetch, `#meldung, .StoryContent`, full remove-list, title/content
/// skip-lists, empty-element removal, and forum comments rendered as blockquotes.
class HeiseAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.heise.de/rss/heise.rdf"
    static let heiseURL = "https://www.heise.de/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.heise.de/rss/heise.rdf", "Main Feed"),
        ("https://www.heise.de/rss/heise-security.rdf", "Security"),
        ("https://www.heise.de/rss/heise-developer.rdf", "Developer"),
        ("https://www.heise.de/rss/heise-top.rdf", "Top News"),
    ]

    static let titleSkipList = [
        "die Bilder der Woche", "Produktwerker", "heise-Angebot", "#TGIQF", "heise+",
        "#heiseshow:", "Mein Scrum ist kaputt", "software-architektur.tv", "Developer Snapshots",
    ]

    var heiseOptions: HeiseOptions {
        if case .heise(let o) = config.options { return o }
        return HeiseOptions()
    }

    override var contentSelector: String { "#meldung, .StoryContent" }

    override var selectorsToRemove: [String] {
        [".ad-label", ".ad", ".article-sidebar", "section",
         "a[name='meldung.ho.bottom.zurstartseite']",
         ".a-article-header__lead", ".a-article-header__title",
         ".a-article-header__publish-info", ".a-article-header__service",
         "a-lightbox.article-image", "figure.a-article-header__image",
         "div[data-component='RecommendationBox']", ".opt-in__content-container", ".a-box",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])",
         ".a-u-inline", ".redakteurskuerzel", ".branding", "a-gift", "aside",
         "script", "style", "noscript", "footer", ".rte__list",
         "#wtma_teaser_ho_vertrieb_inline_branding"]
    }

    // MARK: - Predefined feed

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    // MARK: - Filters

    override func shouldInclude(_ article: AggregatedArticle) -> Bool {
        !Self.titleSkipList.contains { article.title.contains($0) }
    }

    override func postFilter(_ article: AggregatedArticle) -> Bool {
        !article.content.lowercased().contains("event sourcing")
    }

    // MARK: - Multi-page article URL

    /// Returns the all-pages variant of an article URL (server: `seite=all`).
    static func allPagesURL(_ url: String) -> String {
        guard !url.contains("seite=all") else { return url }
        return url.contains("?") ? "\(url)&seite=all" : "\(url)?seite=all"
    }

    /// Returns the canonical article URL without the `seite=all` page param (for footer/comments).
    static func canonicalURL(_ url: String) -> String {
        url.replacingOccurrences(of: "&seite=all", with: "")
            .replacingOccurrences(of: "?seite=all", with: "")
    }

    /// Build the fetch URL up front so the page is fetched as a single all-pages document.
    /// `identifier` stays the canonical link (dedup key); `url` carries the fetch param.
    override func makeArticle(from entry: FeedEntry) -> AggregatedArticle {
        var article = super.makeArticle(from: entry)
        article.url = Self.allPagesURL(article.url)
        return article
    }

    /// The page is fetched against the `seite=all` URL (carried on `article.url` from
    /// `makeArticle`), but the persisted/user-visible URL is restored to canonical afterward.
    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var enriched = try await super.enrich(article, entry: entry)
        enriched.url = Self.canonicalURL(enriched.url)
        return enriched
    }

    /// Overridable for tests: fetches the forum page HTML.
    func fetchCommentsHTML(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw AggregatorError.contentFetch("bad forum url") }
        return try await HTTPClient.fetchHTML(u)
    }

    // MARK: - Content processing (override to inject comments before the footer)

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        // Empty-element removal (server: p/div/span with no text and no images).
        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        let canonicalURL = Self.canonicalURL(article.url)

        // Forum comments from the raw page HTML (rawContent set by FullWebsiteAggregator.enrich).
        var commentsHTML: String?
        if heiseOptions.includeComments {
            commentsHTML = try? await extractComments(articleURL: canonicalURL, pageHTML: article.rawContent,
                                                      maxComments: heiseOptions.maxComments)
        }
        return ContentFormatter.format(content: body, title: article.title, url: canonicalURL,
                                       headerHTML: header?.html, commentsHTML: commentsHTML)
    }

    // MARK: - Comment extraction

    func extractComments(articleURL: String, pageHTML: String, maxComments: Int) async throws -> String? {
        guard maxComments > 0 else { return nil }
        let base = articleURL.contains("heise.de/-") ? Self.heiseURL : articleURL
        guard let forumURL = try findForumURL(pageHTML: pageHTML, base: base) else { return nil }

        let forumHTML = try await fetchCommentsHTML(forumURL)
        let doc = try HTMLUtils.parse(forumHTML)
        let elements = try findCommentElements(doc)
        guard !elements.isEmpty else { return nil }

        var parts: [String] = []
        for el in elements.prefix(maxComments) {
            if let html = try processCommentElement(el) { parts.append(html) }
        }
        guard !parts.isEmpty else { return nil }
        let header = "<h3><a href=\"\(forumURL)\">Comments</a></h3>"
        return "<section>\(header)\(parts.joined())</section>"
    }

    private func findForumURL(pageHTML: String, base: String) throws -> String? {
        let doc = try HTMLUtils.parse(pageHTML)
        // 1. JSON-LD discussionUrl.
        for script in try doc.select("script[type=application/ld+json]") {
            let raw = try script.html()
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            let items: [[String: Any]] = (obj as? [[String: Any]]) ?? [(obj as? [String: Any])].compactMap { $0 }
            for item in items {
                if let discussion = item["discussionUrl"] as? String {
                    return URL(string: discussion, relativeTo: URL(string: base))?.absoluteString ?? discussion
                }
            }
        }
        // 2. Fallback forum link.
        if let a = try doc.select("a[href*=/forum/][href*=comment], footer a[href*=/forum/]").first() {
            let href = try a.attr("href")
            if !href.isEmpty {
                return URL(string: href, relativeTo: URL(string: base))?.absoluteString ?? href
            }
        }
        return nil
    }

    private func findCommentElements(_ doc: Document) throws -> [Element] {
        for selector in ["li.posting_element", "[id^=posting_]", ".posting", ".a-comment"] {
            let found = try doc.select(selector).array()
            if !found.isEmpty { return found }
        }
        return []
    }

    private func processCommentElement(_ el: Element) throws -> String? {
        if el.tagName() == "li" { return try processListItemComment(el) }
        return try processFullViewComment(el)
    }

    private func processListItemComment(_ el: Element) throws -> String? {
        var author = "Unknown"
        if let a = try el.select(".tree_thread_list--written_by_user, .pseudonym").first() {
            author = try a.text()
        }
        guard let link = try el.select("a.posting_subject").first() else { return nil }
        let title = try link.text()
        let href = try link.attr("href")
        let commentURL = URL(string: href, relativeTo: URL(string: Self.heiseURL))?.absoluteString ?? href
        return "<blockquote><p><strong>\(author)</strong> | <a href=\"\(commentURL)\">source</a></p>"
            + "<div><p>\(title)</p></div></blockquote>"
    }

    private func processFullViewComment(_ el: Element) throws -> String? {
        var author = "Unknown"
        for selector in ["a[href*=/forum/heise-online/Meinungen]", ".pseudonym", ".username", "strong"] {
            if let a = try el.select(selector).first() {
                let text = try a.text()
                if !text.isEmpty, text.count < 50 { author = text; break }
            }
        }
        var content = ""
        for selector in [".text", ".posting-content", ".comment-body", "p"] {
            if let c = try el.select(selector).first() { content = try c.outerHtml(); break }
        }
        guard !content.isEmpty else { return nil }
        let id = (try? el.attr("id")) ?? ""
        let anchor = id.isEmpty ? "comment" : id
        return "<blockquote><p><strong>\(author)</strong> | <a href=\"#\(anchor)\">source</a></p>"
            + "<div>\(content)</div></blockquote>"
    }
}
