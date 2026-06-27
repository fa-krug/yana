import Foundation
import SwiftSoup

/// Tagesschau.de. Ports core/aggregators/tagesschau/: textabsatz/section-heading extraction,
/// MediaPlayer header, livestream/podcast/video skip-lists, 42 predefined feeds.
class TagesschauAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml"
    static let baseURL = "https://www.tagesschau.de"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml", "Alle Meldungen"),
        ("https://www.tagesschau.de/index~rss2.xml", "Startseite"),
        ("https://www.tagesschau.de/inland/index~rss2.xml", "Inland"),
        ("https://www.tagesschau.de/inland/innenpolitik/index~rss2.xml", "Innenpolitik"),
        ("https://www.tagesschau.de/inland/gesellschaft/index~rss2.xml", "Gesellschaft"),
        ("https://www.tagesschau.de/inland/regional/index~rss2.xml", "Regional (Alle)"),
        ("https://www.tagesschau.de/inland/regional/badenwuerttemberg/index~rss2.xml", "Baden-Württemberg"),
        ("https://www.tagesschau.de/inland/regional/bayern/index~rss2.xml", "Bayern"),
        ("https://www.tagesschau.de/inland/regional/berlin/index~rss2.xml", "Berlin"),
        ("https://www.tagesschau.de/inland/regional/brandenburg/index~rss2.xml", "Brandenburg"),
        ("https://www.tagesschau.de/inland/regional/bremen/index~rss2.xml", "Bremen"),
        ("https://www.tagesschau.de/inland/regional/hamburg/index~rss2.xml", "Hamburg"),
        ("https://www.tagesschau.de/inland/regional/hessen/index~rss2.xml", "Hessen"),
        ("https://www.tagesschau.de/inland/regional/mecklenburgvorpommern/index~rss2.xml", "Mecklenburg-Vorpommern"),
        ("https://www.tagesschau.de/inland/regional/niedersachsen/index~rss2.xml", "Niedersachsen"),
        ("https://www.tagesschau.de/inland/regional/nordrheinwestfalen/index~rss2.xml", "Nordrhein-Westfalen"),
        ("https://www.tagesschau.de/inland/regional/rheinlandpfalz/index~rss2.xml", "Rheinland-Pfalz"),
        ("https://www.tagesschau.de/inland/regional/saarland/index~rss2.xml", "Saarland"),
        ("https://www.tagesschau.de/inland/regional/sachsen/index~rss2.xml", "Sachsen"),
        ("https://www.tagesschau.de/inland/regional/sachsenanhalt/index~rss2.xml", "Sachsen-Anhalt"),
        ("https://www.tagesschau.de/inland/regional/schleswigholstein/index~rss2.xml", "Schleswig-Holstein"),
        ("https://www.tagesschau.de/inland/regional/thueringen/index~rss2.xml", "Thüringen"),
        ("https://www.tagesschau.de/ausland/index~rss2.xml", "Ausland"),
        ("https://www.tagesschau.de/ausland/europa/index~rss2.xml", "Europa"),
        ("https://www.tagesschau.de/ausland/amerika/index~rss2.xml", "Amerika"),
        ("https://www.tagesschau.de/ausland/afrika/index~rss2.xml", "Afrika"),
        ("https://www.tagesschau.de/ausland/asien/index~rss2.xml", "Asien"),
        ("https://www.tagesschau.de/ausland/ozeanien/index~rss2.xml", "Ozeanien"),
        ("https://www.tagesschau.de/wirtschaft/index~rss2.xml", "Wirtschaft"),
        ("https://www.tagesschau.de/wirtschaft/finanzen/index~rss2.xml", "Finanzen"),
        ("https://www.tagesschau.de/wirtschaft/unternehmen/index~rss2.xml", "Unternehmen"),
        ("https://www.tagesschau.de/wirtschaft/verbraucher/index~rss2.xml", "Verbraucher"),
        ("https://www.tagesschau.de/wirtschaft/technologie/index~rss2.xml", "Technologie (Wirtschaft)"),
        ("https://www.tagesschau.de/wirtschaft/weltwirtschaft/index~rss2.xml", "Weltwirtschaft"),
        ("https://www.tagesschau.de/wirtschaft/konjunktur/index~rss2.xml", "Konjunktur"),
        ("https://www.tagesschau.de/wissen/index~rss2.xml", "Wissen"),
        ("https://www.tagesschau.de/wissen/gesundheit/index~rss2.xml", "Gesundheit"),
        ("https://www.tagesschau.de/wissen/klima/index~rss2.xml", "Klima & Umwelt"),
        ("https://www.tagesschau.de/wissen/forschung/index~rss2.xml", "Forschung"),
        ("https://www.tagesschau.de/wissen/technologie/index~rss2.xml", "Technologie (Wissen)"),
        ("https://www.tagesschau.de/faktenfinder/index~rss2.xml", "Faktenfinder"),
        ("https://www.tagesschau.de/investigativ/index~rss2.xml", "Investigativ"),
    ]   // 42 feeds — exactly the server's list. Do not pad.

    static let titleSkipList = ["tagesschau", "tagesthemen", "11KM-Podcast", "Podcast 15 Minuten", "15 Minuten:"]

    var tagesschauOptions: TagesschauOptions {
        if case .tagesschau(let o) = config.options { return o }
        return TagesschauOptions()
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    // MARK: - Filtering

    override func shouldInclude(_ article: AggregatedArticle) -> Bool {
        let title = article.title
        let url = article.url
        let opts = tagesschauOptions
        if opts.skipLivestreams, title.contains("Livestream:") { return false }
        if title.hasPrefix("Bilder:") { return false }   // photo-gallery articles, no readable text
        if Self.titleSkipList.contains(where: { title.contains($0) }) { return false }
        if url.contains("bilder/blickpunkte") { return false }
        if opts.skipVideos, url.lowercased().contains("video") { return false }
        return true
    }

    // MARK: - Content extraction (textabsatz paragraphs / section headings only)

    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        // RSS-provided content captured before extraction, used as the fallback below.
        let rssContent = article.content
        do {
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw
            let extracted = try Self.extractTagesschauContent(raw)
            let mediaHeader = try? Self.extractMediaHeader(raw)
            // Some Tagesschau pages are interactive widgets (e.g. the DWD weather warnings page)
            // that carry no textabsatz paragraphs and no media player. Importing the empty page
            // extraction would yield a blank article, so fall back to the RSS content instead.
            guard !extracted.isEmpty || mediaHeader != nil else {
                article.content = try await processContent(rssContent, article: article, headerHTML: nil)
                return article
            }
            // Standard processing without a generic header (media header handled separately).
            let body = try await processContent(extracted, article: article, headerHTML: nil)
            article.content = (mediaHeader ?? "") + body
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            if Task.isCancelled { throw CancellationError() }   // cancelled run: don't persist feed-only content
            article.content = (try? await processContent(rssContent, article: article, headerHTML: nil)) ?? ""
            return article
        } catch {
            if error.isCancellationError || Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(rssContent, article: article, headerHTML: nil)) ?? ""
            return article
        }
    }

    /// textabsatz-`<p>` + section-heading-`<h2>` only, skipping teaser/bigfive/accordion/related
    /// ancestors. Section headings are `meldung__subhead` on current tagesschau.de/sportschau.de
    /// pages; `trenner` is the legacy class, kept for backward compatibility. Classless `<h2>`s
    /// ("Mehr zum Thema", "Top-Themen") are navigation and intentionally excluded.
    static func extractTagesschauContent(_ html: String) throws -> String {
        let doc = try HTMLUtils.parse(html)
        let skipClasses = ["teaser", "bigfive", "accordion", "related"]
        let headingClasses = ["trenner", "meldung__subhead"]
        var parts: [String] = []
        for el in try doc.select("p, h2") {
            if try hasSkippedAncestor(el, skipClasses: skipClasses) { continue }
            let classes = (try? el.classNames()) ?? []
            if el.tagName() == "p", classes.contains(where: { $0.contains("textabsatz") }) {
                let inner = try el.html()
                parts.append("<p>\(inner)</p>")
            } else if el.tagName() == "h2",
                      classes.contains(where: { cls in headingClasses.contains { cls.contains($0) } }) {
                let text = try el.text()
                parts.append("<h2>\(text)</h2>")
            }
        }
        return parts.joined()
    }

    private static func hasSkippedAncestor(_ el: Element, skipClasses: [String]) throws -> Bool {
        var current: Element? = el.parent()
        while let node = current {
            let classes = (try? node.classNames()) ?? []
            if classes.contains(where: { cls in skipClasses.contains { cls.contains($0) } }) { return true }
            current = node.parent()
        }
        return false
    }

    // MARK: - Media header (div[data-v-type=MediaPlayer])

    // Builds the header from MediaPlayer stream JSON. The poster falls back to the sibling/parent
    // `<img>` in the DOM (mirrors the server) since the JSON rarely carries one. The Python
    // `sharing@web.embedCode` iframe path is intentionally not ported (omission is deliberate).
    static func extractMediaHeader(_ html: String) throws -> String? {
        let doc = try HTMLUtils.parse(html)
        var players = try doc.select("div[data-v-type=MediaPlayer]").array().filter {
            ((try? $0.classNames()) ?? []).contains { $0.lowercased().contains("mediaplayer") }
        }
        let teaserTop = players.filter { ((try? $0.classNames()) ?? []).contains { $0.lowercased().contains("teaser-top") } }
        if !teaserTop.isEmpty { players = teaserTop }

        for player in players {
            let dataV = try player.attr("data-v")
            guard !dataV.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(decodeEntities(dataV).utf8)) as? [String: Any],
                  let mc = json["mc"] as? [String: Any] else { continue }
            let streams = (mc["streams"] as? [[String: Any]]) ?? []
            let isAudioOnly = !streams.isEmpty && streams.allSatisfy { ($0["isAudioOnly"] as? Bool) == true }
            let imageURL = playerImage(player: player, mc: mc)
            if let html = buildHeaderFromStreams(streams: streams, isAudioOnly: isAudioOnly, imageURL: imageURL) {
                return html
            }
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func playerImage(player: Element, mc: [String: Any]) -> String? {
        let fields = ["poster", "image", "thumbnail", "preview", "cover"]
        for f in fields { if let v = mc[f] as? String, !v.isEmpty { return absolutize(v) } }
        for stream in (mc["streams"] as? [[String: Any]]) ?? [] {
            for f in fields { if let v = stream[f] as? String, !v.isEmpty { return absolutize(v) } }
        }
        if let dom = playerImageFromDOM(player) { return absolutize(dom) }
        return nil
    }

    /// Most Tagesschau video/audio pages carry no poster in the MediaPlayer JSON; the preview
    /// image sits in a sibling/parent `<picture>` in the DOM. Mirrors the server's DOM fallback.
    private static func playerImageFromDOM(_ player: Element) -> String? {
        if let parent = player.parent(),
           let src = try? parent.select("img").first()?.attr("src"), !src.isEmpty { return src }
        if let prev = try? player.previousElementSibling(),
           let src = try? prev.select("img").first()?.attr("src"), !src.isEmpty { return src }
        return nil
    }

    private static func absolutize(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("/") { return baseURL + url }
        return url
    }

    private static func buildHeaderFromStreams(streams: [[String: Any]], isAudioOnly: Bool, imageURL: String?) -> String? {
        if isAudioOnly {
            guard let media = findMedia(streams, type: "audio") else { return nil }
            let img = imageURL.map {
                "<div class=\"media-image\"><img src=\"\($0)\" alt=\"Article image\" "
                    + "style=\"max-width: 100%; height: auto; border-radius: 8px;\"></div>"
            } ?? ""
            return "<header class=\"media-header\">\(img)<div class=\"media-player\" style=\"width: 100%;\">"
                + "<audio controls preload=\"auto\" style=\"width: 100%;\"><source src=\"\(media.url)\" type=\"\(media.mime)\">"
                + "Your browser does not support the audio element.</audio></div></header>"
        } else {
            guard let media = findMedia(streams, type: "video") else { return nil }
            let poster = imageURL.map { "poster=\"\($0)\"" } ?? ""
            return "<header class=\"media-header\"><div class=\"media-player\" style=\"width: 100%;\">"
                + "<video controls preload=\"auto\" \(poster) style=\"width: 100%;\"><source src=\"\(media.url)\" type=\"\(media.mime)\">"
                + "Your browser does not support the video element.</video></div></header>"
        }
    }

    private static func findMedia(_ streams: [[String: Any]], type: String) -> (url: String, mime: String)? {
        for stream in streams {
            for media in (stream["media"] as? [[String: Any]]) ?? [] {
                if let url = media["url"] as? String {
                    let mime = (media["mimeType"] as? String) ?? ""
                    if mime.lowercased().contains(type) { return (url, mime) }
                }
            }
        }
        return nil
    }
}
