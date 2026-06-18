import Foundation
import WebKit
import Testing
@testable import Yana

@MainActor
@Suite("ReaderLinkPolicy")
struct ReaderLinkPolicyTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // The initial article load (programmatic loadHTMLString under the base origin) stays in place.
    @Test func initialArticleLoadStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.baseOrigin), navigationType: .other, targetIsMainFrame: true) == false)
    }

    // A tapped absolute external link leaves the reader.
    @Test func tappedAbsoluteLinkOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://example.com/story"), navigationType: .linkActivated, targetIsMainFrame: true) == true)
    }

    // A relative link that resolved against the base origin (empty <base href>) must still leave
    // the reader — this is the bug: it used to be mistaken for our own document and load in place.
    @Test func tappedBaseOriginLinkOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.baseOrigin + "/some/relative/path"),
            navigationType: .linkActivated, targetIsMainFrame: true) == true)
    }

    // Subframe loads (e.g. video embeds) stay in place even though they are external web URLs.
    @Test func subframeEmbedStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://www.youtube.com/embed/abc"),
            navigationType: .other, targetIsMainFrame: false) == false)
    }

    // Our local image scheme always loads in place.
    @Test func localImageSchemeStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.imageScheme + "://cache/123"),
            navigationType: .other, targetIsMainFrame: true) == false)
    }

    // Non-web schemes the user taps (mailto, tel) leave the app.
    @Test func tappedMailtoOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("mailto:someone@example.com"), navigationType: .linkActivated, targetIsMainFrame: true) == true)
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("tel:+1234567890"), navigationType: .linkActivated, targetIsMainFrame: true) == true)
    }

    // A non-web scheme that is not a user tap stays in place (e.g. about:blank).
    @Test func nonTappedNonWebSchemeStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("about:blank"), navigationType: .other, targetIsMainFrame: true) == false)
    }
}
