import Foundation

/// Maps a `FeedConfig` to a concrete `Aggregator`. Phase 4b+ fills in the `switch`.
final class AggregatorRegistry: Sendable {
    static let shared = AggregatorRegistry()

    private init() {}

    /// Build an aggregator for the given config, or `nil` if none is registered yet.
    func makeAggregator(_ config: FeedConfig, credentials: AggregatorCredentials) -> (any Aggregator)? {
        // Phase 4b+: switch over `config.type` and return concrete aggregators.
        nil
    }
}
