import Foundation

/// Maps a `FeedConfig` to a concrete `Aggregator`. Phase 4b+ fills in the `switch`.
final class AggregatorRegistry: Sendable {
    static let shared = AggregatorRegistry()

    private init() {}

    /// Build an aggregator for the given config, or `nil` if none is registered yet.
    func makeAggregator(_ config: FeedConfig, credentials: AggregatorCredentials) -> (any Aggregator)? {
        switch config.type {
        case .feedContent: return FeedContentAggregator(config: config, credentials: credentials)
        case .fullWebsite: return FullWebsiteAggregator(config: config, credentials: credentials)
        // 4d scrapers and 4e social/media add their cases here.
        default: return nil
        }
    }
}
