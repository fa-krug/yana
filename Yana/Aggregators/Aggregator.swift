import Foundation

/// Resolved secrets handed to an aggregator at construction time.
struct AggregatorCredentials: Sendable {
    var redditClientID: String?
    var redditClientSecret: String?
    var youtubeAPIKey: String?
}

/// A pluggable content source. Concrete implementations are added in Phase 3.
protocol Aggregator: Sendable {
    static var type: AggregatorType { get }

    /// Validate configuration before a run. Throws if the feed is misconfigured.
    func validate() throws

    /// Fetch and return articles for the feed.
    func aggregate() async throws -> [AggregatedArticle]
}

enum AggregatorError: Error, LocalizedError {
    case missingIdentifier
    case missingAPIKey(AggregatorAPIKey)
    case notImplemented(AggregatorType)

    var errorDescription: String? {
        switch self {
        case .missingIdentifier:
            String(localized: "This feed needs an identifier (URL, subreddit, or channel).")
        case .missingAPIKey:
            String(localized: "This aggregator requires an API key. Add it in Settings.")
        case .notImplemented(let type):
            String(localized: "The \(type.displayName) aggregator is not available yet.")
        }
    }
}
