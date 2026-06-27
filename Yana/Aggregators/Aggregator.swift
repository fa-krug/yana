import Foundation

/// Resolved secrets handed to an aggregator at construction time.
struct AggregatorCredentials: Sendable {
    var redditClientID: String?
    var redditClientSecret: String?
    var youtubeAPIKey: String?

    /// Read the user-supplied API keys out of the Keychain. Empty strings map to `nil`.
    static func resolved() -> AggregatorCredentials {
        func nonEmpty(_ item: KeychainService.APIKeyItem) -> String? {
            let value = KeychainService.loadAPIKey(for: item)
            return (value?.isEmpty == false) ? value : nil
        }
        return AggregatorCredentials(
            redditClientID: nonEmpty(.redditClientID),
            redditClientSecret: nonEmpty(.redditClientSecret),
            youtubeAPIKey: nonEmpty(.youtubeAPIKey)
        )
    }
}

/// A pluggable content source. Concrete implementations land in Phase 4b+.
/// Constructed by an `AggregatorFactory` that captures its `FeedConfig` + credentials.
protocol Aggregator: Sendable {
    /// Validate configuration before a run. Throws if the feed is misconfigured.
    func validate() throws

    /// Fetch and return articles for the feed.
    func aggregate() async throws -> [AggregatedArticle]

    /// Re-fetch a single, already-known article's content from its source. Returns `nil` when
    /// the aggregator cannot meaningfully re-fetch one item in isolation (the caller then falls
    /// back to a forced full-feed reload).
    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle?

    /// Remote URL of this feed's logo image when the aggregator can source one directly (e.g.
    /// from its API). `nil` means "derive the logo from the site favicon instead".
    func logoImageURL() async -> String?
}

extension Aggregator {
    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? { nil }
    func logoImageURL() async -> String? { nil }
}

extension Error {
    /// True when this error represents cooperative task cancellation — either Swift's
    /// `CancellationError` or `URLError(.cancelled)` (which `URLSession` throws when its task is
    /// cancelled). A cancelled run — most commonly an expired `BGAppRefreshTask` window — must
    /// stop cleanly rather than persist half-fetched or degraded (feed-only) content.
    var isCancellationError: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

enum AggregatorError: Error, LocalizedError {
    case missingIdentifier
    case missingAPIKey(AggregatorAPIKey)
    case notImplemented(AggregatorType)
    case articleSkip(statusCode: Int)
    case contentFetch(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .missingIdentifier:
            String(localized: "This feed needs an identifier (URL, subreddit, or channel).")
        case .missingAPIKey:
            String(localized: "This aggregator requires an API key. Add it in Settings.")
        case .notImplemented(let type):
            String(localized: "The \(type.displayName) aggregator is not available yet.")
        case .articleSkip(let code):
            String(localized: "Article skipped (HTTP \(code)).")
        case .contentFetch(let message):
            String(localized: "Could not fetch content: \(message)")
        case .parse(let message):
            String(localized: "Could not parse content: \(message)")
        }
    }
}
