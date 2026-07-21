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

    /// Image fetches use a larger cap than text fetches: a common Reddit GIF (~26 MB — the reported
    /// `i.redd.it/*.gif` on r/memes was 27,569,319 bytes) must clear the image cap, or it is rejected
    /// before download and the post renders with no media at all. The text cap stays tight.
    @Test func imageResponseCapClearsLargeRedditGIF() {
        #expect(HTTPClient.maxImageResponseBytes > HTTPClient.maxResponseBytes)
        #expect(!HTTPClient.exceedsCap(received: 27_569_319, cap: HTTPClient.maxImageResponseBytes),
                "a ~26 MB Reddit GIF must fit under the image cap")
        #expect(HTTPClient.exceedsCap(received: 27_569_319, cap: HTTPClient.maxResponseBytes),
                "the same GIF exceeds the tighter text cap — which is why images need their own")
    }

    /// Image fetches must advertise an image-preferring `Accept`. Reddit's `*.redd.it` CDN
    /// content-negotiates on `Accept` and 307-redirects a `text/html` preference to an HTML
    /// media-viewer page instead of the raw image — so an image fetch advertising text/html receives
    /// undecodable HTML and the image is silently dropped.
    @Test func imageAcceptPrefersImagesNotHTML() {
        #expect(HTTPClient.imageAccept.hasPrefix("image/"))
        #expect(!HTTPClient.imageAccept.contains("text/html"))
        #expect(HTTPClient.htmlAccept.hasPrefix("text/html"))
    }

    @Test func makeRequestSetsUserAgentAndAccept() {
        let url = URL(string: "https://preview.redd.it/x.jpg")!
        let imageReq = HTTPClient.makeRequest(url: url, timeout: 30, accept: HTTPClient.imageAccept)
        #expect(imageReq.value(forHTTPHeaderField: "User-Agent") == HTTPClient.userAgent)
        #expect(imageReq.value(forHTTPHeaderField: "Accept") == HTTPClient.imageAccept)

        let htmlReq = HTTPClient.makeRequest(url: url, timeout: 30, accept: HTTPClient.htmlAccept)
        #expect(htmlReq.value(forHTTPHeaderField: "Accept") == HTTPClient.htmlAccept)
    }
}
