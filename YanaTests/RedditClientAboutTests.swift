import Foundation
import Testing
@testable import Yana

@Suite("RedditClient.fetchSubredditAbout")
struct RedditClientAboutTests {
    private let token = #"{"access_token":"T"}"#

    private func client(aboutJSON: String) -> RedditClient {
        RedditClient(clientID: "id", clientSecret: "s", userAgent: "Yana/1.0") { req in
            req.url!.absoluteString.contains("access_token")
                ? Data(self.token.utf8) : Data(aboutJSON.utf8)
        }
    }

    @Test func prefersCommunityIcon() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"https://r/ci.png?w=256","icon_img":"https://r/i.png"}}"#)
        #expect(await c.fetchSubredditAbout("swift") == "https://r/ci.png?w=256")
    }

    @Test func fallsBackToIconImg() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"","icon_img":"https://r/i.png"}}"#)
        #expect(await c.fetchSubredditAbout("swift") == "https://r/i.png")
    }

    @Test func decodesHTMLEntities() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"https://r/ci.png?a=1&amp;b=2"}}"#)
        #expect(await c.fetchSubredditAbout("swift") == "https://r/ci.png?a=1&b=2")
    }

    @Test func nilWhenBothEmpty() async {
        let c = client(aboutJSON: #"{"data":{"community_icon":"","icon_img":""}}"#)
        #expect(await c.fetchSubredditAbout("swift") == nil)
    }
}
