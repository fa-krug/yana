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

    /// The verified outcome of resolving a user-entered URL to a working feed: the canonical feed
    /// URL and the number of entries the parse produced. Reported back in the editor so the user
    /// sees exactly what will be saved.
    struct FeedResolveResult: Equatable, Sendable {
        let feedURL: String
        let entryCount: Int
    }

    /// Why a resolve-and-test attempt failed, classified for a user-facing message.
    enum FeedResolveError: Error, Equatable {
        case invalidURL       // empty input or unparseable as a URL
        case network          // the page or feed could not be fetched
        case noFeedFound      // reachable, but no feed and no advertised `<link rel="alternate">`
        case notAFeed         // a feed URL was found/entered but did not parse into any entries
    }

    /// Like `resolvedFeedURL`, but *verifies* the result: it fetches and parses the resolved feed,
    /// returning the canonical URL plus its entry count on success, or a classified failure. Unlike
    /// `resolvedFeedURL` (best-effort, save-path), a discovered `<link rel="alternate">` feed is
    /// re-fetched and parsed so the caller knows it actually works. `fetch` is injectable for tests.
    static func resolveAndTest(
        _ raw: String,
        fetch: (URL) async throws -> Data = { try await HTTPClient.fetchData($0).data }
    ) async -> Result<FeedResolveResult, FeedResolveError> {
        let normalized = normalized(raw)
        guard !normalized.isEmpty, let url = URL(string: normalized) else { return .failure(.invalidURL) }
        guard let data = try? await fetch(url) else { return .failure(.network) }

        // Already a feed → done.
        if let parsed = try? FeedParser.parse(data), !parsed.entries.isEmpty {
            return .success(FeedResolveResult(feedURL: normalized, entryCount: parsed.entries.count))
        }

        // HTML page advertising a feed → fetch and parse that feed to confirm it works.
        if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
           let feedURL = FeedDiscovery.feedURL(inHTML: html, baseURL: url) {
            guard let feedData = try? await fetch(feedURL) else { return .failure(.network) }
            if let parsed = try? FeedParser.parse(feedData), !parsed.entries.isEmpty {
                return .success(FeedResolveResult(feedURL: feedURL.absoluteString, entryCount: parsed.entries.count))
            }
            return .failure(.notAFeed)
        }

        return .failure(.noFeedFound)
    }
}
