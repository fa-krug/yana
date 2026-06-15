import Foundation

/// AI post-processing toggles, shared by every aggregator (mirrors the Yana server's
/// shared `ai_*` options).
struct AIOptions: Codable, Sendable, Equatable {
    var summarize = false
    var improveWriting = false
    var translate = false
    var translateLanguage = "English"
}

struct WebsiteOptions: Codable, Sendable, Equatable {
    var useFullContent = true
    var customContentSelector = ""
    var customSelectorsToRemove = ""
    var ai = AIOptions()
}

struct FeedContentOptions: Codable, Sendable, Equatable {
    /// When true, follow each entry's link and extract the full article body.
    var fetchFullContent = false
    var ai = AIOptions()
}

struct RedditOptions: Codable, Sendable, Equatable {
    var subredditSort = "hot"   // hot | new | top | rising
    var minComments = 5
    var commentLimit = 10
    var includeHeaderImage = true
    var ai = AIOptions()
}

struct YouTubeOptions: Codable, Sendable, Equatable {
    var commentLimit = 10
    var ai = AIOptions()
}

struct PodcastOptions: Codable, Sendable, Equatable {
    var includePlayer = true
    var includeDownloadLink = true
    var artworkSize = 300
    var ai = AIOptions()
}

/// Shared options shape for the managed site-specific scrapers. Individual scrapers read
/// the subset relevant to them; unused flags are harmless.
struct ManagedOptions: Codable, Sendable, Equatable {
    var includeComments = true
    var maxComments = 5
    var showAltText = true
    var skipVideos = true
    var skipLivestreams = true
    var skipAds = true
    var combinePages = true
    var removeEmptyElements = true
    var ai = AIOptions()
}

/// Typed per-feed aggregator configuration. Swift synthesizes `Codable` for enums with
/// `Codable` associated values; SwiftData persists this as a composite attribute.
enum AggregatorOptions: Codable, Sendable, Equatable {
    case fullWebsite(WebsiteOptions)
    case feedContent(FeedContentOptions)
    case reddit(RedditOptions)
    case youtube(YouTubeOptions)
    case podcast(PodcastOptions)
    case managed(ManagedOptions)

    /// The AI block, regardless of which case is active.
    var ai: AIOptions {
        switch self {
        case .fullWebsite(let o): o.ai
        case .feedContent(let o): o.ai
        case .reddit(let o): o.ai
        case .youtube(let o): o.ai
        case .podcast(let o): o.ai
        case .managed(let o): o.ai
        }
    }
}
