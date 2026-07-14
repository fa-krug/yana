import Foundation
import SwiftSoup

/// MacTechNews (mactechnews.de). Ports core/aggregators/mactechnews/aggregator.py:
/// forced News feed, `.MtnArticle` content, numeric-image-ID dedup, relative-URL resolution,
/// multi-page article combining, and comment extraction.
class MactechnewsAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let forcedFeed = "https://www.mactechnews.de/Rss/News.x"

    static let identifierChoices: [(value: String, label: String)] = []   // forced, no choices

    /// The feed is forced (`forcedFeed`), so `config.identifier` is irrelevant and not required.
    override func validate() throws {}

    override var contentSelector: String { ".MtnArticle" }

    override var selectorsToRemove: [String] {
        [".NewsPictureMobile", "aside", "script", "style", "iframe", "noscript", "svg",
         "header", ".TexticonBox.Right"]
    }

    var mactechnewsOptions: MactechnewsOptions {
        if case .mactechnews(let o) = config.options { return o }
        return MactechnewsOptions()
    }

    /// Skip the recurring "TechTicker:" link-roundup posts.
    override func shouldInclude(_ article: AggregatedArticle) -> Bool {
        !article.title.hasPrefix("TechTicker:")
    }

    /// Overridable seam for tests to inject feed data.
    func fetchFeedData(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        return try await HTTPClient.fetchData(u).data
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let data = try await fetchFeedData(Self.forcedFeed)   // identifier is ignored — feed forced
        return try FeedParser.parse(data).entries
    }

    /// Overridable seam: fetch an additional page of a multi-page article.
    func fetchAdditionalPage(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw AggregatorError.contentFetch("bad page url") }
        return try await HTTPClient.fetchHTML(u)
    }

    /// The header image URL for dedup, normally discovered from the page's og:image.
    /// Overridable so tests can supply it directly.
    func makeHeaderImageURL(forPage html: String) -> String? {
        guard let doc = try? HTMLUtils.parse(html),
              let meta = try? doc.select("meta[property=og:image]").first(),
              let content = try? meta.attr("content"), !content.isEmpty else { return nil }
        return content
    }

    static func extractImageID(_ url: String) -> String? {
        guard let r = url.range(of: #"\.(\d{5,})\.\w+$"#, options: .regularExpression) else { return nil }
        let match = String(url[r])
        if let idRange = match.range(of: #"\d{5,}"#, options: .regularExpression) {
            return String(match[idRange])
        }
        return nil
    }

    // MARK: - Enrich (multi-page + comments)

    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        do {
            let first = try await fetchArticleHTML(article.url)
            article.rawContent = first
            let header = await HeaderElementExtractor.extract(
                articleURL: article.url, title: article.title, store: store,
                credentials: credentials, pageHTML: first)

            // Combine pages if enabled and pagination detected.
            var contentDivs: [String] = extractContentDivHTML(from: first).map { [$0] } ?? []
            if mactechnewsOptions.combinePages {
                let pages = detectPagination(html: first)
                if pages.count > 1 {
                    contentDivs = []
                    for page in pages.sorted() {
                        let pageURL = page == 1 ? article.url : pageURLFor(base: article.url, page: page)
                        let html = page == 1 ? first : ((try? await fetchAdditionalPage(pageURL)) ?? "")
                        if let div = extractContentDivHTML(from: html) { contentDivs.append(div) }
                    }
                }
            }

            let merged = mergeContentDivs(contentDivs)
            let processed = try await processMactechnewsContent(merged, article: article, header: header)
            article.content = processed
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            if Task.isCancelled { throw CancellationError() }   // cancelled run: don't persist feed-only content
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        } catch {
            if error.isCancellationError || Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        }
    }

    // MARK: - Pagination (ports multipage_handler.py + 4099b10 fix)

    /// Detects `?page=N` / `&page=N` query-param links and the current page rendered as
    /// `<strong>N</strong>` (server fix 4099b10). Always includes page 1.
    func detectPagination(html: String) -> Set<Int> {
        var pages: Set<Int> = [1]
        guard let doc = try? HTMLUtils.parse(html) else { return pages }

        // Links with ?page=N or &page=N.
        for link in (try? doc.select("a[href]").array()) ?? [] {
            guard let href = try? link.attr("href") else { continue }
            if let r = href.range(of: #"[?&]page=(\d+)"#, options: .regularExpression) {
                let match = String(href[r])
                if let numRange = match.range(of: #"\d+"#, options: .regularExpression),
                   let n = Int(match[numRange]) { pages.insert(n) }
            }
        }

        // Current page rendered as <strong>N</strong> without a link (4099b10).
        for strong in (try? doc.select("strong").array()) ?? [] {
            if let text = try? strong.text(), let n = Int(text) { pages.insert(n) }
        }

        return pages
    }

    /// Builds the URL for page N using query parameters (mactechnews uses `?page=N`).
    private func pageURLFor(base: String, page: Int) -> String {
        base.contains("?") ? "\(base)&page=\(page)" : "\(base)?page=\(page)"
    }

    private func extractContentDivHTML(from html: String) -> String? {
        guard let doc = try? HTMLUtils.parse(html),
              let div = try? doc.select(contentSelector).first() else { return nil }
        return try? div.html()
    }

    private func mergeContentDivs(_ divs: [String]) -> String {
        "<div class=\"MtnArticle\">\(divs.joined(separator: "\n\n"))</div>"
    }

    // MARK: - Content processing

    func processMactechnewsContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        let base = URL(string: article.url)

        // Numeric-image-ID dedup against the header image.
        if let headerURL = makeHeaderImageURL(forPage: article.rawContent),
           let headerID = Self.extractImageID(headerURL) {
            for img in try doc.select("img") {
                var src = try img.attr("src")
                if src.isEmpty || src.hasPrefix("data:") {
                    src = largestSrcsetURL(try img.attr("srcset")) ?? ""
                }
                if !src.isEmpty, Self.extractImageID(src) == headerID { try img.remove() }
            }
        }

        // Resolve relative URLs.
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

        // Remove unwanted elements.
        for selector in selectorsToRemove {
            for el in try doc.select(selector) { try el.remove() }
        }

        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { _ = try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: base)
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)

        // Comment extraction from the raw (first-page) HTML.
        var commentsHTML: String?
        let opts = mactechnewsOptions
        if opts.includeComments {
            commentsHTML = extractComments(pageHTML: article.rawContent,
                                           articleURL: article.url,
                                           maxComments: opts.maxComments)
        }

        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: commentsHTML)
    }

    // Keep processFullContent for the base-class fallback path (single-page, no multi-page logic).
    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        try await processMactechnewsContent(html, article: article, header: header)
    }

    // MARK: - Comment extraction (ports comment_extractor.py)

    /// Extracts up to `maxComments` comments from `div.MtnCommentScroll > div.MtnComment`.
    /// Returns an HTML `<section>` mirroring Heise's comment output shape, or nil if none found.
    func extractComments(pageHTML: String, articleURL: String, maxComments: Int) -> String? {
        guard maxComments > 0 else { return nil }
        guard let doc = try? HTMLUtils.parse(pageHTML),
              let scroll = try? doc.select("div.MtnCommentScroll").first() else { return nil }
        let comments = (try? scroll.select("div.MtnComment").array()) ?? []
        guard !comments.isEmpty else { return nil }

        var parts: [String] = []
        for el in comments.prefix(maxComments) {
            if let html = processCommentElement(el, articleURL: articleURL) { parts.append(html) }
        }
        guard !parts.isEmpty else { return nil }

        let commentsURL = "\(articleURL)#comments"
        let header = "<h3><a href=\"\(commentsURL)\">\(String(localized: "Comments"))</a></h3>"
        return "<section>\(header)\(parts.joined())</section>"
    }

    private func processCommentElement(_ el: Element, articleURL: String) -> String? {
        let author: String
        if let a = try? el.select("span.MtnCommentAccountName").first(), let text = try? a.text(), !text.isEmpty {
            author = text
        } else {
            author = String(localized: "Unknown")
        }

        // Timestamp: join all nested spans.
        var timestamp = ""
        if let timeEl = try? el.select("span.MtnCommentTime").first() {
            let spans = (try? timeEl.select("span").array()) ?? []
            if spans.isEmpty {
                timestamp = (try? timeEl.text()) ?? ""
            } else {
                timestamp = spans.compactMap { try? $0.text() }.joined(separator: " ")
            }
        }

        guard let textEl = try? el.select("div.MtnCommentText").first(),
              let commentText = try? textEl.outerHtml() else { return nil }

        let commentID = (try? el.attr("id")) ?? ""
        let anchorURL = commentID.isEmpty ? "\(articleURL)#comments" : "\(articleURL)#\(commentID)"
        let tsDisplay = timestamp.isEmpty ? "" : " (\(timestamp))"

        return "<blockquote>"
            + "<p><strong>\(author)</strong>\(tsDisplay) | <a href=\"\(anchorURL)\">\(String(localized: "source"))</a></p>"
            + "<div>\(commentText)</div>"
            + "</blockquote>"
    }
}
