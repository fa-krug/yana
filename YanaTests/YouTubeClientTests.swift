import Foundation
import Testing
@testable import Yana

@Suite("YouTubeClient")
struct YouTubeClientTests {
    private let channelsJSON = """
    {"items":[{"id":"UC123456789012345678901234",
       "snippet":{"title":"My Channel","customUrl":"@mychan",
         "thumbnails":{"high":{"url":"https://img/h.jpg"}}},
       "contentDetails":{"relatedPlaylists":{"uploads":"UU123"}}}]}
    """
    private let playlistJSON = """
    {"items":[{"contentDetails":{"videoId":"vid111aaaaa"}}]}
    """
    private let videosJSON = """
    {"items":[{"id":"vid111aaaaa",
       "snippet":{"title":"Cool Video","description":"Line1\\nLine2","publishedAt":"2023-11-14T00:00:00Z",
         "thumbnails":{"maxres":{"url":"https://img/m.jpg"},"high":{"url":"https://img/h.jpg"}}},
       "statistics":{"viewCount":"100"},"contentDetails":{"duration":"PT5M"}}]}
    """
    private let commentsJSON = """
    {"items":[{"id":"cm1","snippet":{"topLevelComment":{"snippet":{
       "authorDisplayName":"viewer","textDisplay":"Nice <b>vid</b>"}}}}]}
    """

    /// Thread-safe box so the `@Sendable` fetch closure can record the request it saw
    /// (Swift 6 strict concurrency forbids mutating a captured `var` inside it).
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.lock(); value = request; lock.unlock() }
        var captured: URLRequest? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func client() -> YouTubeClient {
        YouTubeClient(apiKey: "K") { request in
            let url = request.url!.absoluteString
            if url.contains("/channels") { return Data(self.channelsJSON.utf8) }
            if url.contains("/playlistItems") { return Data(self.playlistJSON.utf8) }
            if url.contains("/videos") { return Data(self.videosJSON.utf8) }
            if url.contains("/commentThreads") { return Data(self.commentsJSON.utf8) }
            if url.contains("/search") { return Data(self.channelsJSON.utf8) }   // unused here
            return Data("{}".utf8)
        }
    }

    @Test func resolveChannelIDForRawID() async throws {
        let id = try await client().resolveChannelID("UC123456789012345678901234")
        #expect(id == "UC123456789012345678901234")
    }

    @Test func fetchChannelDataReturnsUploadsPlaylist() async throws {
        let data = try await client().fetchChannelData("UC123456789012345678901234")
        #expect(data.uploadsPlaylistID == "UU123")
        #expect(data.title == "My Channel")
    }

    @Test func fetchVideosResolvesDetails() async throws {
        let videos = try await client().fetchVideos(playlistID: "UU123", max: 10)
        #expect(videos.count == 1)
        #expect(videos.first?.id == "vid111aaaaa")
        #expect(videos.first?.title == "Cool Video")
        #expect(videos.first?.description.contains("Line1") == true)
        #expect(videos.first?.thumbnailURL == "https://img/m.jpg")    // maxres priority
    }

    @Test func fetchVideoCommentsParsed() async throws {
        let comments = try await client().fetchVideoComments(videoID: "vid111aaaaa", max: 10)
        #expect(comments.first?.author == "viewer")
        #expect(comments.first?.textHTML == "Nice <b>vid</b>")
    }

    @Test func apiKeyAppendedToEveryRequest() async throws {
        let box = RequestBox()
        let c = YouTubeClient(apiKey: "SECRET") { request in
            box.set(request)
            return Data(self.channelsJSON.utf8)
        }
        _ = try await c.fetchChannelData("UC123456789012345678901234")
        #expect(box.captured?.url?.absoluteString.contains("key=SECRET") == true)
    }
}
