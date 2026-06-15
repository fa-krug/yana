import Foundation

/// Immutable, `Sendable` snapshot of everything an aggregator needs for one run.
/// Built on the main actor from a SwiftData `Feed`, then handed to an aggregator that
/// may run off the main actor. Aggregators never touch SwiftData directly.
struct FeedConfig: Sendable {
    var type: AggregatorType
    var identifier: String
    var dailyLimit: Int
    var options: AggregatorOptions
    /// Number of articles already imported for this feed since the start of today.
    var collectedToday: Int

    @MainActor
    init(feed: Feed, collectedToday: Int) {
        self.type = feed.type
        self.identifier = feed.identifier
        self.dailyLimit = feed.dailyLimit
        self.options = feed.options
        self.collectedToday = collectedToday
    }

    /// Memberwise init for tests and future call sites.
    init(type: AggregatorType, identifier: String, dailyLimit: Int, options: AggregatorOptions, collectedToday: Int) {
        self.type = type
        self.identifier = identifier
        self.dailyLimit = dailyLimit
        self.options = options
        self.collectedToday = collectedToday
    }
}

/// Builds an `Aggregator` for a run, or `nil` if no concrete aggregator is registered yet.
/// Phase 4b–4e populate the registry; the service records `nil` as a per-feed error.
typealias AggregatorFactory = @Sendable (FeedConfig, AggregatorCredentials) -> (any Aggregator)?
