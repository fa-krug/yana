import Foundation
import Testing
@testable import Yana

@Suite("ImageSchemeHandler")
struct ImageSchemeHandlerTests {
    @Test func hashExtractedFromSchemeURL() {
        let url = URL(string: "\(ReaderWeb.imageScheme)://abc123")!
        #expect(ImageSchemeHandler.hash(from: url) == "abc123")
    }
}
