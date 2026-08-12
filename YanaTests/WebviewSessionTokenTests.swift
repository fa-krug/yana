import Foundation
import Testing
@testable import Yana

@Suite("WebviewSessionToken")
struct WebviewSessionTokenTests {
    @Test func decodesTokenAndExpiresAt() throws {
        let json = #"{"token":"abc123","expiresAt":"2026-08-11T12:00:00Z"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(WebviewSessionToken.self, from: json)
        #expect(result.token == "abc123")
        #expect(result.expiresAt == Date(timeIntervalSince1970: 1_786_449_600))
    }
}
