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
        case .heise, .merkur, .tagesschau, .caschysBlog, .mactechnews, .meinMmo, .theVerge:
            return makeNewsScraper(config.type, config: config, credentials: credentials)
        case .explosm, .darkLegacy, .oglaf:
            return makeComicScraper(config.type, config: config, credentials: credentials)
        case .reddit, .youtube, .podcast:
            return makeSocial(config.type, config: config, credentials: credentials)
        }
    }

    /// News-site scrapers.
    private func makeNewsScraper(_ type: AggregatorType, config: FeedConfig,
                                 credentials: AggregatorCredentials) -> (any Aggregator)? {
        switch type {
        case .heise: return HeiseAggregator(config: config, credentials: credentials)
        case .merkur: return MerkurAggregator(config: config, credentials: credentials)
        case .tagesschau: return TagesschauAggregator(config: config, credentials: credentials)
        case .caschysBlog: return CaschysBlogAggregator(config: config, credentials: credentials)
        case .mactechnews: return MactechnewsAggregator(config: config, credentials: credentials)
        case .meinMmo: return MeinMmoAggregator(config: config, credentials: credentials)
        case .theVerge: return TheVergeAggregator(config: config, credentials: credentials)
        default: return nil
        }
    }

    /// Comic scrapers.
    private func makeComicScraper(_ type: AggregatorType, config: FeedConfig,
                                  credentials: AggregatorCredentials) -> (any Aggregator)? {
        switch type {
        case .explosm: return ExplosmAggregator(config: config, credentials: credentials)
        case .darkLegacy: return DarkLegacyAggregator(config: config, credentials: credentials)
        case .oglaf: return OglafAggregator(config: config, credentials: credentials)
        default: return nil
        }
    }

    /// Social / media sources.
    private func makeSocial(_ type: AggregatorType, config: FeedConfig,
                            credentials: AggregatorCredentials) -> (any Aggregator)? {
        switch type {
        case .reddit: return RedditAggregator(config: config, credentials: credentials)
        case .youtube: return YouTubeAggregator(config: config, credentials: credentials)
        case .podcast: return PodcastAggregator(config: config, credentials: credentials)
        default: return nil
        }
    }
}
