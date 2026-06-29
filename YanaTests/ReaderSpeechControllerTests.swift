import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ReaderSpeechController")
struct ReaderSpeechControllerTests {

    @Test func stripsHttpURLFromText() {
        let input = "Read more at https://example.com/path?q=1 today."
        let output = ReaderSpeechController.strippingURLs(from: input)
        #expect(!output.contains("https://"))
        #expect(!output.contains("example.com"))
        #expect(output == "Read more at today.")
    }

    @Test func stripsBareWebAddress() {
        let input = "Visit www.example.com for details."
        let output = ReaderSpeechController.strippingURLs(from: input)
        #expect(!output.contains("example.com"))
        #expect(output == "Visit for details.")
    }

    @Test func stripsMultipleURLs() {
        let input = "First https://a.com then https://b.com end."
        let output = ReaderSpeechController.strippingURLs(from: input)
        #expect(!output.contains("a.com"))
        #expect(!output.contains("b.com"))
        #expect(output == "First then end.")
    }

    @Test func leavesURLFreeTextUntouched() {
        let input = "Just a normal sentence without any links."
        #expect(ReaderSpeechController.strippingURLs(from: input) == input)
    }

    @Test func collapsesWhitespaceLeftByRemovedURL() {
        // A line that is only a URL should not leave behind a blank line / stray spaces.
        let input = "Intro paragraph.\n\nhttps://example.com\n\nNext paragraph."
        let output = ReaderSpeechController.strippingURLs(from: input)
        #expect(!output.contains("example.com"))
        #expect(!output.contains("\n\n\n"))
        #expect(output.contains("Intro paragraph."))
        #expect(output.contains("Next paragraph."))
    }
}
