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
}
