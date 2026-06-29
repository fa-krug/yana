import Foundation
import Testing
@testable import Yana

@Suite("YouTubeAggregator")
struct YouTubeAggregatorTests {
    let channelsJSON = """
    {"items":[{"id":"UC123456789012345678901234",
       "snippet":{"title":"Cool Channel","customUrl":"@mychan",
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
    {"items":[{"id":"cm1",
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
        let a = try #require(try await makeAggregator(key: "K").aggregate().first)
        #expect(a.title == "Cool Video")
        #expect(a.identifier == "https://www.youtube.com/watch?v=vid111aaaaa")
        #expect(a.content.contains("youtube-embed-container"))
        #expect(a.content.contains("youtube-facade"))                   // click-to-play preview poster
        #expect(a.content.contains("i.ytimg.com/vi/vid111aaaaa/hqdefault.jpg"))  // thumbnail poster
        #expect(a.content.contains("youtube-nocookie.com/embed/vid111aaaaa"))
        #expect(a.content.contains("youtube-description"))
        #expect(a.content.contains("Line1<br>Line2"))
        #expect(a.content.contains("Nice video"))
        #expect(a.content.contains("<strong>viewer</strong>"))
        #expect(!a.content.contains("Source:"))                         // source link lives in the toolbar now
        #expect(a.author == "@mychan")                                  // customURL preferred over title
        #expect(a.iconURL == "https://img/m.jpg")                       // per-video thumbnail
        #expect(a.content.contains("youtube-comments"))                 // comments wrapper class
        // After the sanitization tail (SwiftSoup parse → serialize) the `&` in the comment link is
        // HTML-entity-encoded; `BlockParser` decodes it back, so the rendered link is unchanged.
        #expect(a.content.contains("watch?v=vid111aaaaa&amp;lc=cm1"))   // comment source link
    }

    @Test func contentParsesIntoPlayableEmbedBlock() async throws {
        // The reported bug: the poster rendered but with no play button and no tap target, because
        // the facade reached `BlockParser` with a raw `class` (not `data-sanitized-class`) and so
        // fell through to a bare image block. Running the content through `finishSanitization` makes
        // `embedFacade` recognize it as a playable YouTube embed.
        let a = try #require(try await makeAggregator(key: "K").aggregate().first)
        let blocks = BlockParser.blocks(fromHTML: a.content, baseURL: URL(string: a.url))
        func embeds(_ blocks: [Block]) -> [Embed] {
            blocks.flatMap { block -> [Embed] in
                switch block {
                case .embed(let e): return [e]
                case .blockquote(let inner): return embeds(inner)
                case .list(_, let items): return items.flatMap(embeds)
                default: return []
                }
            }
        }
        let videoEmbed = try #require(embeds(blocks).first { $0.provider == .youtube })
        #expect(videoEmbed.externalURL == "https://www.youtube.com/watch?v=vid111aaaaa")
        #expect(videoEmbed.thumbnailRef?.contains("hqdefault.jpg") == true)
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

    @Test func logoImageURLReturnsChannelIcon() async {
        // makeAggregator's fixture returns channelsJSON with snippet.thumbnails.high = https://img/c.jpg
        #expect(await makeAggregator(key: "K").logoImageURL() == "https://img/c.jpg")
    }

    @Test func logoImageURLNilWithoutKey() async {
        #expect(await makeAggregator(key: nil).logoImageURL() == nil)
    }

    @Test func refetchRebuildsSingleVideo() async throws {
        let seed = AggregatedArticle(title: "Old title", identifier: "https://www.youtube.com/watch?v=vid111aaaaa",
                                     url: "https://www.youtube.com/watch?v=vid111aaaaa",
                                     rawContent: "", content: "OLD", date: .now, author: "@mychan", iconURL: nil)
        let a = try #require(try await makeAggregator(key: "K").refetch(seed))
        #expect(a.identifier == "https://www.youtube.com/watch?v=vid111aaaaa")
        #expect(a.title == "Cool Video")                                 // refreshed from the API
        #expect(a.content.contains("youtube-nocookie.com/embed/vid111aaaaa"))
        #expect(a.content.contains("Line1<br>Line2"))                    // description
        #expect(a.content.contains("Nice video"))                        // comments
        #expect(a.author == "@mychan")                                   // carried from seed (no channel resolve)
    }

    @Test func refetchReturnsNilForUnparseableURL() async throws {
        let seed = AggregatedArticle(title: "x", identifier: "not-a-video", url: "https://example.com/x",
                                     rawContent: "", content: "", date: .now, author: "", iconURL: nil)
        let result = try await makeAggregator(key: "K").refetch(seed)
        #expect(result == nil)
    }
}
