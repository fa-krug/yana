import Foundation
import WebKit
import Testing
@testable import Yana

@MainActor
@Suite("ReaderLinkPolicy")
struct ReaderLinkPolicyTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // The initial article load (the one programmatic loadHTMLString the reader initiates) stays in
    // place. It is identified by the caller's flag, not by navigation type or URL.
    @Test func initialArticleLoadStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.baseOrigin), navigationType: .other,
            targetIsMainFrame: true, isExpectedArticleLoad: true) == false)
    }

    // A tapped absolute external link leaves the reader.
    @Test func tappedAbsoluteLinkOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://example.com/story"), navigationType: .linkActivated,
            targetIsMainFrame: true, isExpectedArticleLoad: false) == true)
    }

    // The bug: a tapped relative link with no usable <base href> resolves against the base origin
    // AND WebKit reports it as `.other` — indistinguishable from the initial load by type or URL.
    // It must still leave the reader, which only the load flag (false here) can decide.
    @Test func tappedBaseOriginLinkReportedAsOtherOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.baseOrigin + "/some/relative/path"),
            navigationType: .other, targetIsMainFrame: true, isExpectedArticleLoad: false) == true)
    }

    // The same link arriving as `.linkActivated` also leaves the reader.
    @Test func tappedBaseOriginLinkOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.baseOrigin + "/some/relative/path"),
            navigationType: .linkActivated, targetIsMainFrame: true, isExpectedArticleLoad: false) == true)
    }

    // Subframe loads (e.g. video embeds) stay in place even though they are external web URLs.
    @Test func subframeEmbedStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://www.youtube.com/embed/abc"),
            navigationType: .other, targetIsMainFrame: false, isExpectedArticleLoad: false) == false)
    }

    // Our local image scheme always loads in place.
    @Test func localImageSchemeStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.imageScheme + "://cache/123"),
            navigationType: .other, targetIsMainFrame: true, isExpectedArticleLoad: false) == false)
    }

    // Non-web schemes the user taps (mailto, tel) leave the app.
    @Test func tappedMailtoOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("mailto:someone@example.com"), navigationType: .linkActivated,
            targetIsMainFrame: true, isExpectedArticleLoad: false) == true)
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("tel:+1234567890"), navigationType: .linkActivated,
            targetIsMainFrame: true, isExpectedArticleLoad: false) == true)
    }

    // A non-web scheme that is not a user tap stays in place (e.g. about:blank).
    @Test func nonTappedNonWebSchemeStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("about:blank"), navigationType: .other,
            targetIsMainFrame: true, isExpectedArticleLoad: false) == false)
    }
}
