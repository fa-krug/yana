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

/// `the_verge` has no extra options — AI only.
struct TheVergeOptions: Codable, Sendable, Equatable {
    var ai = AIOptions()
}

/// `ars_technica` has no extra options — AI only.
struct ArsTechnicaOptions: Codable, Sendable, Equatable {
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
    case theVerge(TheVergeOptions)
    case arsTechnica(ArsTechnicaOptions)
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
        case .theVerge(let o): o.ai
        case .arsTechnica(let o): o.ai
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

// MARK: - Forward/backward-compatible decoding
//
// These options structs are persisted inside `Feed.options` (a Codable composite
// attribute in SwiftData). When a new field is added to one of them, rows written by
// an older build lack that key. Swift's *synthesized* `Decodable` requires every
// non-optional key to be present, and SwiftData's `CompositeKeyedDecoding` traps
// (EXC_BREAKPOINT) — not throws — on a missing key, which crashed existing users on
// the first feed update after a field was added (e.g. `MeinMmoOptions.includeComments`).
//
// Each custom `init(from:)` below decodes every field with `decodeIfPresent`, falling
// back to the struct's default value, so missing keys (older data) and extra keys
// (newer data) both decode cleanly. They live in extensions so the synthesized default
// `init()`, `CodingKeys`, and `encode(to:)` are all preserved.

extension AIOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summarize = try c.decodeIfPresent(Bool.self, forKey: .summarize) ?? summarize
        improveWriting = try c.decodeIfPresent(Bool.self, forKey: .improveWriting) ?? improveWriting
        translate = try c.decodeIfPresent(Bool.self, forKey: .translate) ?? translate
        translateLanguage = try c.decodeIfPresent(String.self, forKey: .translateLanguage) ?? translateLanguage
    }
}

extension WebsiteOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useFullContent = try c.decodeIfPresent(Bool.self, forKey: .useFullContent) ?? useFullContent
        customContentSelector = try c.decodeIfPresent(String.self, forKey: .customContentSelector) ?? customContentSelector
        customSelectorsToRemove = try c.decodeIfPresent(String.self, forKey: .customSelectorsToRemove) ?? customSelectorsToRemove
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension FeedContentOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension TheVergeOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension ArsTechnicaOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension RedditOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subredditSort = try c.decodeIfPresent(String.self, forKey: .subredditSort) ?? subredditSort
        minComments = try c.decodeIfPresent(Int.self, forKey: .minComments) ?? minComments
        commentLimit = try c.decodeIfPresent(Int.self, forKey: .commentLimit) ?? commentLimit
        includeHeaderImage = try c.decodeIfPresent(Bool.self, forKey: .includeHeaderImage) ?? includeHeaderImage
        minAgeHours = try c.decodeIfPresent(Int.self, forKey: .minAgeHours) ?? minAgeHours
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension YouTubeOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commentLimit = try c.decodeIfPresent(Int.self, forKey: .commentLimit) ?? commentLimit
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension PodcastOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includePlayer = try c.decodeIfPresent(Bool.self, forKey: .includePlayer) ?? includePlayer
        includeDownloadLink = try c.decodeIfPresent(Bool.self, forKey: .includeDownloadLink) ?? includeDownloadLink
        artworkSize = try c.decodeIfPresent(Int.self, forKey: .artworkSize) ?? artworkSize
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension HeiseOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeComments = try c.decodeIfPresent(Bool.self, forKey: .includeComments) ?? includeComments
        maxComments = try c.decodeIfPresent(Int.self, forKey: .maxComments) ?? maxComments
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension MerkurOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removeEmptyElements = try c.decodeIfPresent(Bool.self, forKey: .removeEmptyElements) ?? removeEmptyElements
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension TagesschauOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skipLivestreams = try c.decodeIfPresent(Bool.self, forKey: .skipLivestreams) ?? skipLivestreams
        skipVideos = try c.decodeIfPresent(Bool.self, forKey: .skipVideos) ?? skipVideos
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension ExplosmOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showAltText = try c.decodeIfPresent(Bool.self, forKey: .showAltText) ?? showAltText
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension DarkLegacyOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showAltText = try c.decodeIfPresent(Bool.self, forKey: .showAltText) ?? showAltText
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension CaschysBlogOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skipAds = try c.decodeIfPresent(Bool.self, forKey: .skipAds) ?? skipAds
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension MactechnewsOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combinePages = try c.decodeIfPresent(Bool.self, forKey: .combinePages) ?? combinePages
        includeComments = try c.decodeIfPresent(Bool.self, forKey: .includeComments) ?? includeComments
        maxComments = try c.decodeIfPresent(Int.self, forKey: .maxComments) ?? maxComments
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension OglafOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showAltText = try c.decodeIfPresent(Bool.self, forKey: .showAltText) ?? showAltText
        convertToBase64 = try c.decodeIfPresent(Bool.self, forKey: .convertToBase64) ?? convertToBase64
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}

extension MeinMmoOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combinePages = try c.decodeIfPresent(Bool.self, forKey: .combinePages) ?? combinePages
        includeComments = try c.decodeIfPresent(Bool.self, forKey: .includeComments) ?? includeComments
        maxComments = try c.decodeIfPresent(Int.self, forKey: .maxComments) ?? maxComments
        ai = try c.decodeIfPresent(AIOptions.self, forKey: .ai) ?? ai
    }
}
