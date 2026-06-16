import Foundation

/// What kind of value the feed's `identifier` holds for a given aggregator.
enum AggregatorIdentifierKind: Sendable {
    case url            // a feed/website/podcast URL
    case subreddit      // a subreddit name, e.g. "swift"
    case youtubeChannel // a YouTube channel id/handle
    case none           // fixed source, no identifier needed
}

/// Which user-supplied API key an aggregator needs.
enum AggregatorAPIKey: Sendable {
    case none
    case reddit
    case youtube
}

/// One case per content source, mirroring the Yana server's aggregator choices.
enum AggregatorType: String, CaseIterable, Codable, Sendable, Identifiable {
    case fullWebsite = "full_website"
    case feedContent = "feed_content"
    case heise
    case merkur
    case tagesschau
    case explosm
    case darkLegacy = "dark_legacy"
    case caschysBlog = "caschys_blog"
    case mactechnews
    case oglaf
    case meinMmo = "mein_mmo"
    case youtube
    case reddit
    case podcast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullWebsite: "Full Website"
        case .feedContent: "Feed Content (RSS/Atom)"
        case .heise: "Heise"
        case .merkur: "Merkur"
        case .tagesschau: "Tagesschau"
        case .explosm: "Explosm"
        case .darkLegacy: "Dark Legacy Comics"
        case .caschysBlog: "Caschy's Blog"
        case .mactechnews: "MacTechNews"
        case .oglaf: "Oglaf"
        case .meinMmo: "Mein-MMO"
        case .youtube: "YouTube"
        case .reddit: "Reddit"
        case .podcast: "Podcast"
        }
    }

    var identifierKind: AggregatorIdentifierKind {
        switch self {
        case .reddit: .subreddit
        case .youtube: .youtubeChannel
        case .explosm, .darkLegacy, .oglaf, .tagesschau: .none
        default: .url
        }
    }

    /// Predefined RSS-feed choices for the feed editor's identifier Picker (empty = free-form URL or forced feed).
    var identifierChoices: [(value: String, label: String)] {
        switch self {
        case .heise: HeiseAggregator.identifierChoices
        case .merkur: MerkurAggregator.identifierChoices
        case .tagesschau: TagesschauAggregator.identifierChoices
        case .caschysBlog: CaschysBlogAggregator.identifierChoices
        case .meinMmo: MeinMmoAggregator.identifierChoices
        default: []
        }
    }

    var requiredAPIKey: AggregatorAPIKey {
        switch self {
        case .reddit: .reddit
        case .youtube: .youtube
        default: .none
        }
    }

    /// The default typed options for a freshly created feed of this type.
    var defaultOptions: AggregatorOptions {
        switch self {
        case .fullWebsite: .fullWebsite(WebsiteOptions())
        case .feedContent: .feedContent(FeedContentOptions())
        case .reddit: .reddit(RedditOptions())
        case .youtube: .youtube(YouTubeOptions())
        case .podcast: .podcast(PodcastOptions())
        case .heise: .heise(HeiseOptions())
        case .merkur: .merkur(MerkurOptions())
        case .tagesschau: .tagesschau(TagesschauOptions())
        case .explosm: .explosm(ExplosmOptions())
        case .darkLegacy: .darkLegacy(DarkLegacyOptions())
        case .caschysBlog: .caschysBlog(CaschysBlogOptions())
        case .mactechnews: .mactechnews(MactechnewsOptions())
        case .oglaf: .oglaf(OglafOptions())
        case .meinMmo: .meinMmo(MeinMmoOptions())
        }
    }
}
