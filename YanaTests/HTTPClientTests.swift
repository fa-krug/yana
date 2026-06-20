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
}
