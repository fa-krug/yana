import Foundation
import Testing
@testable import Yana

@Suite("YouTubeAggregator")
struct YouTubeAggregatorTests {
    let channelsJSON = """
    {"items":[{"id":"UC123456789012345678901234",
       "snippet":{"title":"Cool Channel","customUrl":"@cool",
         "thumbnails":{"high":{"url":"https://img/c.jpg"}}},
       "contentDetails":{"relatedPlaylists":{"uploads":"UU123456789012345678901234"}}}]}
    """

    let playlistJSON = """
    {"items":[{"contentDetails":{"videoId":"vid111aaaaa"}}]}
    """

    let videosJSON = """
    {"items":[{"id":"vid111aaaaa",
       "snippet":{"title":"Cool Video","description":"Line1\\nLine2","publishedAt":"2023-11-14T00:00:00Z",
         "thumbnails":{"maxres":{"url":"https://img/m.jpg"}}},
       "statistics":{"viewCount":"1234"},"contentDetails":{"duration":"PT5M30S"}}]}
    """

    let commentsJSON = """
    {"items":[{"id":"ct1",
       "snippet":{"topLevelComment":{"snippet":{"authorDisplayName":"viewer","textDisplay":"Nice video"}}}}]}
    """

    private func makeAggregator(key: String?) -> YouTubeAggregator {
        let config = FeedConfig(type: .youtube, identifier: "UC123456789012345678901234", dailyLimit: 10,
                                options: .youtube(YouTubeOptions()), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: nil, redditClientSecret: nil, youtubeAPIKey: key)
        let client = YouTubeClient(apiKey: key ?? "") { request in
            let url = request.url!.absoluteString
            if url.contains("/channels") { return Data(self.channelsJSON.utf8) }
            if url.contains("/playlistItems") { return Data(self.playlistJSON.utf8) }
            if url.contains("/videos") { return Data(self.videosJSON.utf8) }
            if url.contains("/commentThreads") { return Data(self.commentsJSON.utf8) }
            return Data("{}".utf8)
        }
        return YouTubeAggregator(config: config, credentials: creds, client: client)
    }

    @Test func buildsArticleWithEmbedDescriptionAndComments() async throws {
        let article = try #require(try await makeAggregator(key: "K").aggregate().first)
        #expect(article.title == "Cool Video")
        #expect(article.identifier == "https://www.youtube.com/watch?v=vid111aaaaa")
        #expect(article.content.contains("youtube-embed-container"))
        #expect(article.content.contains("youtube-nocookie.com/embed/vid111aaaaa"))
        #expect(article.content.contains("youtube-description"))
        #expect(article.content.contains("Line1<br>Line2"))
        #expect(article.content.contains("Nice video"))
        #expect(article.content.contains("<strong>viewer</strong>"))
        #expect(article.content.contains("Source:"))
    }

    @Test func missingKeyThrows() async throws {
        await #expect(throws: AggregatorError.self) {
            _ = try await makeAggregator(key: nil).aggregate()
        }
    }

    @Test func escapesScriptInVideoDescription() async throws {
        let videosWithScript = """
        {"items":[{"id":"vid111aaaaa",
           "snippet":{"title":"T","description":"hi <script>alert(1)</script>","publishedAt":"2023-11-14T00:00:00Z",
             "thumbnails":{"maxres":{"url":"https://img/m.jpg"}}},
           "statistics":{"viewCount":"1"},"contentDetails":{"duration":"PT5M"}}]}
        """
        let config = FeedConfig(type: .youtube, identifier: "UC123456789012345678901234", dailyLimit: 10,
                                options: .youtube(YouTubeOptions()), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: nil, redditClientSecret: nil, youtubeAPIKey: "K")
        let client = YouTubeClient(apiKey: "K") { request in
            let url = request.url!.absoluteString
            if url.contains("/channels") { return Data(self.channelsJSON.utf8) }
            if url.contains("/playlistItems") { return Data(self.playlistJSON.utf8) }
            if url.contains("/videos") { return Data(videosWithScript.utf8) }
            if url.contains("/commentThreads") { return Data("{\"items\":[]}".utf8) }
            return Data("{}".utf8)
        }
        let a = try #require(try await YouTubeAggregator(config: config, credentials: creds, client: client).aggregate().first)
        #expect(a.content.contains("&lt;script&gt;"))
        #expect(!a.content.contains("<script>alert"))
    }
}
