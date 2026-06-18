import Foundation
import WebKit
import Testing
@testable import Yana

@MainActor
@Suite("ReaderLinkPolicy")
struct ReaderLinkPolicyTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // The initial article load is `.other` and loads in place.
    @Test func initialArticleLoadStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://www.example.com/a"), navigationType: .other) == false)
    }

    // A tapped absolute http(s) link leaves the reader.
    @Test func tappedAbsoluteLinkOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://example.com/story"), navigationType: .linkActivated) == true)
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("http://example.com/story"), navigationType: .linkActivated) == true)
    }

    // A tapped relative link, resolved against the article's <base href> to a real URL, leaves
    // the reader — this is the bug the origin check used to get wrong.
    @Test func tappedResolvedRelativeLinkOpensExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://www.heise.de/some/relative/path"), navigationType: .linkActivated) == true)
    }

    // Tapped mailto / tel leave the app.
    @Test func tappedMailtoAndTelOpenExternally() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("mailto:someone@example.com"), navigationType: .linkActivated) == true)
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("tel:+1234567890"), navigationType: .linkActivated) == true)
    }

    // Image-scheme requests are `.other` and load in place.
    @Test func localImageSchemeStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url(ReaderWeb.imageScheme + "://cache/123"), navigationType: .other) == false)
    }

    // Non-link navigations (embeds, redirects, programmatic loads) stay in place even for http(s).
    @Test func nonLinkActivatedWebNavStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("https://www.youtube.com/embed/abc"), navigationType: .other) == false)
    }

    // A tapped unknown scheme (e.g. about:blank) stays in place.
    @Test func tappedUnknownSchemeStaysInPlace() {
        #expect(ReaderLinkPolicy.opensExternally(
            url: url("about:blank"), navigationType: .linkActivated) == false)
    }

    // MARK: - JS click interception (externalURL(fromClickedHref:))

    // The injected click handler posts the browser-resolved absolute href; Swift turns the
    // qualifying ones into a URL to open. Relative links arrive already absolutized by the DOM.
    @Test func clickedHttpHrefBecomesExternalURL() {
        #expect(ReaderLinkPolicy.externalURL(fromClickedHref: "https://example.com/story")?.absoluteString
            == "https://example.com/story")
        #expect(ReaderLinkPolicy.externalURL(fromClickedHref: "http://example.com/story")?.absoluteString
            == "http://example.com/story")
    }

    @Test func clickedMailtoAndTelBecomeExternalURL() {
        #expect(ReaderLinkPolicy.externalURL(fromClickedHref: "mailto:a@b.com") != nil)
        #expect(ReaderLinkPolicy.externalURL(fromClickedHref: "tel:+1234567890") != nil)
    }

    // Garbage or non-openable schemes yield nil (the JS side already filters, this is defense).
    @Test func clickedUnsupportedHrefIsNil() {
        #expect(ReaderLinkPolicy.externalURL(fromClickedHref: "about:blank") == nil)
        #expect(ReaderLinkPolicy.externalURL(fromClickedHref: "javascript:void(0)") == nil)
        #expect(ReaderLinkPolicy.externalURL(fromClickedHref: "") == nil)
    }
}
