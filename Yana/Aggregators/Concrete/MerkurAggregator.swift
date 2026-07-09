import Foundation
import SwiftSoup

/// Merkur.de German regional news. Ports core/aggregators/merkur/aggregator.py:
/// `.idjs-Story` content, full remove-list, optional empty-element removal, 18 regional feeds.
class MerkurAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.merkur.de/rssfeed.rdf"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.merkur.de/rssfeed.rdf", "Main Feed"),
        ("https://www.merkur.de/lokales/garmisch-partenkirchen/rssfeed.rdf", "Garmisch-Partenkirchen"),
        ("https://www.merkur.de/lokales/wuermtal/rssfeed.rdf", "Würmtal"),
        ("https://www.merkur.de/lokales/starnberg/rssfeed.rdf", "Starnberg"),
        ("https://www.merkur.de/lokales/fuerstenfeldbruck/rssfeed.rdf", "Fürstenfeldbruck"),
        ("https://www.merkur.de/lokales/dachau/rssfeed.rdf", "Dachau"),
        ("https://www.merkur.de/lokales/freising/rssfeed.rdf", "Freising"),
        ("https://www.merkur.de/lokales/erding/rssfeed.rdf", "Erding"),
        ("https://www.merkur.de/lokales/ebersberg/rssfeed.rdf", "Ebersberg"),
        ("https://www.merkur.de/lokales/muenchen/rssfeed.rdf", "München"),
        ("https://www.merkur.de/lokales/muenchen-lk/rssfeed.rdf", "München Landkreis"),
        ("https://www.merkur.de/lokales/holzkirchen/rssfeed.rdf", "Holzkirchen"),
        ("https://www.merkur.de/lokales/miesbach/rssfeed.rdf", "Miesbach"),
        ("https://www.merkur.de/lokales/region-tegernsee/rssfeed.rdf", "Region Tegernsee"),
        ("https://www.merkur.de/lokales/bad-toelz/rssfeed.rdf", "Bad Tölz"),
        ("https://www.merkur.de/lokales/wolfratshausen/rssfeed.rdf", "Wolfratshausen"),
        ("https://www.merkur.de/lokales/weilheim/rssfeed.rdf", "Weilheim"),
        ("https://www.merkur.de/lokales/schongau/rssfeed.rdf", "Schongau"),
    ]

    var merkurOptions: MerkurOptions {
        if case .merkur(let o) = config.options { return o }
        return MerkurOptions()
    }

    override var contentSelector: String { ".idjs-Story" }

    /// Extract from the dedicated `.idjs-Story` container, not the generic default selectors.
    override var usesFirstContentMatch: Bool { true }

    override var selectorsToRemove: [String] {
        [".id-DonaldBreadcrumb--default", ".id-StoryElement-headline", ".id-StoryElement-image",
         ".lp_west_printAction", ".lp_west_webshareAction", ".id-Recommendation", ".enclosure",
         ".id-Story-timestamp", ".id-Story-authors", ".id-Story-interactionBar", ".id-Comments",
         ".id-ClsPrevention", "egy-discussion", "figcaption", "script", "style",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])", "noscript", "svg",
         ".id-StoryElement-intestitialLink", ".id-StoryElement-embed--fanq"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        if merkurOptions.removeEmptyElements {
            try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
        }
        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }
}
