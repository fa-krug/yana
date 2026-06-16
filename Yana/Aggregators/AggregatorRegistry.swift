import Foundation

/// Maps a `FeedConfig` to a concrete `Aggregator`. Phase 4b+ fills in the `switch`.
final class AggregatorRegistry: Sendable {
    static let shared = AggregatorRegistry()

    private init() {}

    /// Build the concrete aggregator for the given config. Every `AggregatorType` resolves to
    /// an aggregator (the switch is exhaustive, so a future new type forces a compile error).
    func makeAggregator(_ config: FeedConfig, credentials: AggregatorCredentials) -> (any Aggregator)? {
        switch config.type {
        case .feedContent: return FeedContentAggregator(config: config, credentials: credentials)
        case .fullWebsite: return FullWebsiteAggregator(config: config, credentials: credentials)
        case .heise: return HeiseAggregator(config: config, credentials: credentials)
        case .merkur: return MerkurAggregator(config: config, credentials: credentials)
        case .tagesschau: return TagesschauAggregator(config: config, credentials: credentials)
        case .caschysBlog: return CaschysBlogAggregator(config: config, credentials: credentials)
        case .mactechnews: return MactechnewsAggregator(config: config, credentials: credentials)
        case .meinMmo: return MeinMmoAggregator(config: config, credentials: credentials)
        case .explosm: return ExplosmAggregator(config: config, credentials: credentials)
        case .darkLegacy: return DarkLegacyAggregator(config: config, credentials: credentials)
        case .oglaf: return OglafAggregator(config: config, credentials: credentials)
        case .reddit: return RedditAggregator(config: config, credentials: credentials)
        case .youtube: return YouTubeAggregator(config: config, credentials: credentials)
        case .podcast: return PodcastAggregator(config: config, credentials: credentials)
        }
    }
}
