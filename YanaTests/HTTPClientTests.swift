import Foundation
import Testing
@testable import Yana

@Suite("HTTPClient")
struct HTTPClientTests {
    @Test func userAgentIsBotIdentified() {
        #expect(HTTPClient.userAgent.contains("YanaBot"))
    }

    @Test func skipErrorCarriesStatusCode() {
        let error = AggregatorError.articleSkip(statusCode: 404)
        #expect(error.errorDescription?.contains("404") == true)
    }

    @Test func enforcesMaxBytesGuard() {
        #expect(HTTPClient.exceedsCap(received: 11, cap: 10) == true)
        #expect(HTTPClient.exceedsCap(received: 10, cap: 10) == false)
        #expect(HTTPClient.exceedsCap(received: 0, cap: 10) == false)
    }

    @Test func redditCDNHostsUseBrowserUserAgent() {
        // Reddit's image CDN 403s the bot UA; these must switch to the browser UA.
        #expect(HTTPClient.usesBrowserUserAgent(host: "preview.redd.it"))
        #expect(HTTPClient.usesBrowserUserAgent(host: "external-preview.redd.it"))
        #expect(HTTPClient.usesBrowserUserAgent(host: "i.redd.it"))
        #expect(HTTPClient.usesBrowserUserAgent(host: "redd.it"))
        #expect(HTTPClient.usesBrowserUserAgent(host: "PREVIEW.REDD.IT"))   // case-insensitive
    }

    @Test func otherHostsKeepBotUserAgent() {
        #expect(!HTTPClient.usesBrowserUserAgent(host: "reddit.com"))       // API host, separately authed
        #expect(!HTTPClient.usesBrowserUserAgent(host: "oauth.reddit.com"))
        #expect(!HTTPClient.usesBrowserUserAgent(host: "example.com"))
        #expect(!HTTPClient.usesBrowserUserAgent(host: "notredd.it.evil.com"))
        #expect(!HTTPClient.usesBrowserUserAgent(host: nil))
        #expect(HTTPClient.browserUserAgent.contains("Safari"))
    }
}
