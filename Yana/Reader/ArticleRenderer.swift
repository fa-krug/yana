import Foundation
import UIKit

/// Renders a Yana `Article` into themed HTML using NNW's template + stylesheet macros.
/// Adapted from NetNewsWire's ArticleRenderer for Yana's `Article`/`Feed` model.
@MainActor
enum ArticleRenderer {
    typealias Rendering = (style: String, html: String, title: String, baseURL: String)

    /// Body HTML (theme template filled) + resolved CSS + title + base URL.
    static func articleHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize) -> Rendering {
        let title = ContentFormatter.escapeHTML(article.title)
        let style = (try? MacroProcessor.renderedText(
            withTemplate: theme.css ?? "",
            substitutions: styleSubstitutions()
        )) ?? (theme.css ?? "")
        let html = (try? MacroProcessor.renderedText(
            withTemplate: theme.template ?? "",
            substitutions: articleSubstitutions(article: article, title: title, textSize: textSize)
        )) ?? ""
        return (style, html, title, baseURL(for: article))
    }

    /// Complete HTML document: page.html with `style`/`body`/`title`/`baseURL` substituted.
    static func fullPageHTML(article: Article, theme: ArticleTheme, textSize: ArticleTextSize) -> String {
        let rendering = articleHTML(article: article, theme: theme, textSize: textSize)
        let page = ArticleTheme.stringAtPath(Bundle.main.path(forResource: "page", ofType: "html") ?? "") ?? ""
        return (try? MacroProcessor.renderedText(withTemplate: page, substitutions: [
            "title": rendering.title,
            "style": rendering.style,
            "body": rendering.html,
            "baseURL": rendering.baseURL
        ])) ?? ""
    }

    // MARK: - Substitutions

    private static func articleSubstitutions(article: Article, title: String, textSize: ArticleTextSize) -> [String: String] {
        var d = [String: String]()
        let link = article.url

        d["title"] = title
        d["preferred_link"] = link
        d["external_link_label"] = ""
        d["external_link_stripped"] = ""
        d["external_link"] = ""
        d["body"] = article.content
        d["text_size_class"] = textSize.cssClass

        if let hash = article.feed?.logoHash, !hash.isEmpty {
            d["avatar_src"] = "\(ReaderWeb.imageScheme)://\(hash)"
        } else {
            d["avatar_src"] = ""
        }

        d["dateline_style"] = title.isEmpty ? "articleDatelineTitle" : "articleDateline"
        d["feed_link_title"] = ContentFormatter.escapeHTML(article.feed?.name ?? "")
        d["feed_link"] = baseURL(for: article)
        d["byline"] = ContentFormatter.escapeHTML(article.author)

        let date = article.date
        d["datetime_long"] = longDateTime.string(from: date)
        d["datetime_medium"] = mediumDateTime.string(from: date)
        d["datetime_short"] = shortDateTime.string(from: date)
        d["date_long"] = longDate.string(from: date)
        d["date_medium"] = mediumDate.string(from: date)
        d["date_short"] = shortDate.string(from: date)
        d["time_long"] = longTime.string(from: date)
        d["time_medium"] = mediumTime.string(from: date)
        d["time_short"] = shortTime.string(from: date)
        return d
    }

    private static func styleSubstitutions() -> [String: String] {
        ["font-size": String(describing: UIFont.preferredFont(forTextStyle: .body).pointSize)]
    }

    /// scheme://host of the article URL, used as both base href and feed link. Empty if unparseable
    /// or non-http(s).
    private static func baseURL(for article: Article) -> String {
        guard var comps = URLComponents(string: article.url) else { return "" }
        comps.fragment = nil
        comps.path = ""
        comps.query = nil
        guard let url = comps.url, url.scheme == "http" || url.scheme == "https" else { return "" }
        var result = url.absoluteString
        // Trim trailing slash that URLComponents may emit for bare hosts.
        if result.hasSuffix("/") { result = String(result.dropLast()) }
        return result
    }

    // MARK: - Formatters

    private static func formatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter(); f.dateStyle = date; f.timeStyle = time; return f
    }
    private static let longDateTime = formatter(.long, .medium)
    private static let mediumDateTime = formatter(.medium, .short)
    private static let shortDateTime = formatter(.short, .short)
    private static let longDate = formatter(.long, .none)
    private static let mediumDate = formatter(.medium, .none)
    private static let shortDate = formatter(.short, .none)
    private static let longTime = formatter(.none, .long)
    private static let mediumTime = formatter(.none, .medium)
    private static let shortTime = formatter(.none, .short)
}
