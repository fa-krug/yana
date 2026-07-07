import Foundation

/// Normalizes user-entered website/feed URLs and resolves a homepage to the RSS/Atom feed it
/// advertises. The feed editor uses this so a plain domain like `golem.de` becomes a canonical
/// `https://…/feed.xml` (scheme filled in, feed discovered) before it is saved or previewed.
enum FeedURLResolver {
    /// Fill in a missing scheme. Trims surrounding whitespace and, when the string carries no
    /// `http(s)://` scheme, prepends `https://` (rewriting a leading `feed://` to `https://`).
    /// Empty input passes through unchanged.
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
        if lower.hasPrefix("feed://") { return "https://" + String(trimmed.dropFirst("feed://".count)) }
        return "https://" + trimmed
    }

    /// Normalize `raw`, then resolve it to the actual feed URL: if it already parses as a feed the
    /// (normalized) input is returned unchanged; if it is an HTML page advertising a feed via
    /// `<link rel="alternate">`, that feed's absolute URL is returned; otherwise the normalized
    /// input is returned. Never throws — any network/parse failure falls back to the normalized
    /// input, so a resolve failure never blocks saving or previewing. `fetch` is injectable for tests.
    static func resolvedFeedURL(
        _ raw: String,
        fetch: (URL) async throws -> Data = { try await HTTPClient.fetchData($0).data }
    ) async -> String {
        let normalized = normalized(raw)
        guard let url = URL(string: normalized) else { return normalized }
        guard let data = try? await fetch(url) else { return normalized }
        // Already a feed → keep the (normalized) URL.
        if let parsed = try? FeedParser.parse(data), !parsed.entries.isEmpty { return normalized }
        // HTML page → use the feed it advertises, if any.
        if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
           let feedURL = FeedDiscovery.feedURL(inHTML: html, baseURL: url) {
            return feedURL.absoluteString
        }
        return normalized
    }
}
