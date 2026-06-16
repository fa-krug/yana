import Foundation

struct YouTubeChannelData: Sendable {
    var channelID: String
    var title: String
    var customURL: String?
    var uploadsPlaylistID: String?
    var iconURL: String?
}

struct YouTubeVideo: Sendable {
    var id: String
    var title: String
    var description: String
    var publishedAt: Date?
    var thumbnailURL: String?
}

struct YouTubeComment: Sendable {
    var id: String
    var author: String
    var textHTML: String
}

/// Live-search result for the editor picker.
struct YouTubeChannelResult: Sendable, Identifiable {
    var channelID: String        // value saved as the feed identifier
    var title: String
    var handle: String?
    var id: String { channelID }
}
