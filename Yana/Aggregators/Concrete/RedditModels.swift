import Foundation

/// Subset of a Reddit post (`/r/{sub}/{sort}.json` child `data`) needed for aggregation.
struct RedditPostData: Decodable, Sendable {
    var id: String
    var title: String
    var selftext: String
    var url: String
    var permalink: String
    var createdUTC: Double
    var author: String
    var score: Int
    var numComments: Int
    var thumbnail: String?
    var isSelf: Bool
    var isGallery: Bool
    var isVideo: Bool
    var preview: Preview?
    var media: Media?
    var secureMedia: Media?
    var mediaMetadata: [String: MediaMeta]?
    var galleryData: GalleryData?
    var crosspostParentList: [RedditPostData]?

    /// Best available Reddit-hosted video for this post: `media`/`secure_media` carry it for
    /// native `v.redd.it` posts; `preview.reddit_video_preview` carries it for link posts whose
    /// target Reddit transcoded into a preview video (e.g. gfycat/imgur GIFs).
    var redditVideo: RedditVideo? { media?.redditVideo ?? secureMedia?.redditVideo ?? preview?.redditVideoPreview }

    struct Preview: Decodable, Sendable {
        var images: [PreviewImage]
        var redditVideoPreview: RedditVideo?
        struct PreviewImage: Decodable, Sendable {
            var source: Source?
            struct Source: Decodable, Sendable { var url: String? }
        }
        enum CodingKeys: String, CodingKey {
            case images
            case redditVideoPreview = "reddit_video_preview"
        }
    }
    struct Media: Decodable, Sendable {
        var redditVideo: RedditVideo?
        enum CodingKeys: String, CodingKey { case redditVideo = "reddit_video" }
    }
    /// Reddit-hosted video URLs. `hlsURL` is preferred for playback: HLS muxes audio and plays
    /// inline in WKWebView; `fallbackURL` is a plain MP4 (often video-only) used as a last resort.
    struct RedditVideo: Decodable, Sendable {
        var hlsURL: String?
        var fallbackURL: String?
        var isGif: Bool?
        enum CodingKeys: String, CodingKey {
            case hlsURL = "hls_url"
            case fallbackURL = "fallback_url"
            case isGif = "is_gif"
        }
    }
    struct MediaMeta: Decodable, Sendable {
        var e: String?               // "Image" | "AnimatedImage"
        var s: MediaSource?
        struct MediaSource: Decodable, Sendable { var u: String?; var gif: String?; var mp4: String? }
    }
    struct GalleryData: Decodable, Sendable {
        var items: [Item]
        struct Item: Decodable, Sendable {
            var mediaID: String?
            var caption: String?
            // The decoder applies no snake_case strategy, so map Reddit's `media_id` explicitly —
            // otherwise `mediaID` stays nil and every gallery image is silently dropped.
            enum CodingKeys: String, CodingKey {
                case mediaID = "media_id"
                case caption
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, selftext, url, permalink, author, score, thumbnail, preview, media
        case createdUTC = "created_utc"
        case numComments = "num_comments"
        case isSelf = "is_self"
        case isGallery = "is_gallery"
        case isVideo = "is_video"
        case secureMedia = "secure_media"
        case mediaMetadata = "media_metadata"
        case galleryData = "gallery_data"
        case crosspostParentList = "crosspost_parent_list"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        selftext = (try? c.decode(String.self, forKey: .selftext)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        permalink = (try? c.decode(String.self, forKey: .permalink)) ?? ""
        createdUTC = (try? c.decode(Double.self, forKey: .createdUTC)) ?? 0
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        numComments = (try? c.decode(Int.self, forKey: .numComments)) ?? 0
        thumbnail = try? c.decode(String.self, forKey: .thumbnail)
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
        isGallery = (try? c.decode(Bool.self, forKey: .isGallery)) ?? false
        isVideo = (try? c.decode(Bool.self, forKey: .isVideo)) ?? false
        preview = try? c.decode(Preview.self, forKey: .preview)
        media = try? c.decode(Media.self, forKey: .media)
        secureMedia = try? c.decode(Media.self, forKey: .secureMedia)
        mediaMetadata = try? c.decode([String: MediaMeta].self, forKey: .mediaMetadata)
        galleryData = try? c.decode(GalleryData.self, forKey: .galleryData)
        crosspostParentList = try? c.decode([RedditPostData].self, forKey: .crosspostParentList)
    }
}

struct RedditComment: Decodable, Sendable {
    var id: String
    var body: String
    var author: String
    var score: Int
    var permalink: String
    enum CodingKeys: String, CodingKey { case id, body, author, score, permalink }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        permalink = (try? c.decode(String.self, forKey: .permalink)) ?? ""
    }
}

/// Live-search result for the editor picker.
struct RedditSubredditResult: Sendable, Identifiable {
    var displayName: String      // value saved as the feed identifier
    var title: String
    var subscribers: Int
    var id: String { displayName }
}
