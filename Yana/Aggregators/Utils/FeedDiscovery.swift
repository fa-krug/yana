import Foundation
import SwiftSoup

/// Discovers the RSS/Atom feed advertised by an HTML page via its
/// `<link rel="alternate" type="application/rss+xml|atom+xml">` tags. Lets a "full website"
/// feed take a plain homepage URL as its identifier instead of requiring the feed URL upfront.
enum FeedDiscovery {
    /// The first alternate feed href declared in `html`, resolved absolute against `baseURL`.
    /// Prefers RSS, then Atom. Pure — no network — so callers holding the page HTML can reuse it.
    static func feedURL(inHTML html: String, baseURL: URL?) -> URL? {
        guard let doc = try? HTMLUtils.parse(html) else { return nil }
        let links = (try? doc.select("link[rel=alternate][type]").array()) ?? []
        func href(matching types: [String]) -> URL? {
            for link in links {
                let type = ((try? link.attr("type")) ?? "").lowercased()
                guard types.contains(type) else { continue }
                let raw = (try? link.attr("href")) ?? ""
                guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL { return resolved }
                if let direct = URL(string: raw) { return direct }
            }
            return nil
        }
        return href(matching: ["application/rss+xml"]) ?? href(matching: ["application/atom+xml"])
    }

    /// Fetch `pageURL` and return its advertised feed URL, or nil when none is declared.
    /// Overridable fetch keeps it unit-testable.
    static func discoverFeedURL(
        from pageURL: URL,
        fetchHTML: (URL) async throws -> String = { try await HTTPClient.fetchHTML($0) }
    ) async throws -> URL? {
        let html = try await fetchHTML(pageURL)
        return feedURL(inHTML: html, baseURL: pageURL)
    }
}
