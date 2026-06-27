import Foundation

/// AI post-processing toggles, shared by every aggregator.
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

/// `feed_content` has no extra options on the server — AI only.
struct FeedContentOptions: Codable, Sendable, Equatable {
    var ai = AIOptions()
}

struct RedditOptions: Codable, Sendable, Equatable {
    var subredditSort = "hot"   // hot | new | top | rising
    var minComments = 5
    var commentLimit = 10
    var includeHeaderImage = true
    var minAgeHours = 48        // 0–168
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

struct HeiseOptions: Codable, Sendable, Equatable {
    var includeComments = true
    var maxComments = 5
    var ai = AIOptions()
}

struct MerkurOptions: Codable, Sendable, Equatable {
    var removeEmptyElements = true
    var ai = AIOptions()
}

struct TagesschauOptions: Codable, Sendable, Equatable {
    var skipLivestreams = true
    var skipVideos = true
    var ai = AIOptions()
}

struct ExplosmOptions: Codable, Sendable, Equatable {
    var showAltText = true
    var ai = AIOptions()
}

struct DarkLegacyOptions: Codable, Sendable, Equatable {
    var showAltText = true
    var ai = AIOptions()
}

struct CaschysBlogOptions: Codable, Sendable, Equatable {
    var skipAds = true
    var ai = AIOptions()
}

struct MactechnewsOptions: Codable, Sendable, Equatable {
    var combinePages = true
    var includeComments = true
    var maxComments = 5
    var ai = AIOptions()
}

struct OglafOptions: Codable, Sendable, Equatable {
    var showAltText = true
    var convertToBase64 = true
    var ai = AIOptions()
}

struct MeinMmoOptions: Codable, Sendable, Equatable {
    var combinePages = true
    var includeComments = true
    var maxComments = 5
    var ai = AIOptions()
}

/// Typed per-feed aggregator configuration. One case per `AggregatorType`.
enum AggregatorOptions: Codable, Sendable, Equatable {
    case fullWebsite(WebsiteOptions)
    case feedContent(FeedContentOptions)
    case reddit(RedditOptions)
    case youtube(YouTubeOptions)
    case podcast(PodcastOptions)
    case heise(HeiseOptions)
    case merkur(MerkurOptions)
    case tagesschau(TagesschauOptions)
    case explosm(ExplosmOptions)
    case darkLegacy(DarkLegacyOptions)
    case caschysBlog(CaschysBlogOptions)
    case mactechnews(MactechnewsOptions)
    case oglaf(OglafOptions)
    case meinMmo(MeinMmoOptions)

    /// The AI block, regardless of which case is active.
    var ai: AIOptions {
        switch self {
        case .fullWebsite(let o): o.ai
        case .feedContent(let o): o.ai
        case .reddit(let o): o.ai
        case .youtube(let o): o.ai
        case .podcast(let o): o.ai
        case .heise(let o): o.ai
        case .merkur(let o): o.ai
        case .tagesschau(let o): o.ai
        case .explosm(let o): o.ai
        case .darkLegacy(let o): o.ai
        case .caschysBlog(let o): o.ai
        case .mactechnews(let o): o.ai
        case .oglaf(let o): o.ai
        case .meinMmo(let o): o.ai
        }
    }
}
