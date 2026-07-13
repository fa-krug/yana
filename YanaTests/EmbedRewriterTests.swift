import Foundation
import Testing
import SwiftSoup
@testable import Yana

@Suite("EmbedRewriter")
struct EmbedRewriterTests {
    @Test func extractsVideoIDFromVariants() {
        #expect(EmbedRewriter.extractYouTubeID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(EmbedRewriter.extractYouTubeID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5") == "dQw4w9WgXcQ")
        #expect(EmbedRewriter.extractYouTubeID(from: "https://www.youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func extractsVideoIDWhenVNotFirstParam() {
        #expect(EmbedRewriter.extractYouTubeID(from: "https://www.youtube.com/watch?list=PL123&v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(EmbedRewriter.extractYouTubeID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5") == "dQw4w9WgXcQ")
    }

    @Test func youTubeEmbedMatchesProxyShape() {
        let html = EmbedRewriter.youTubeEmbedHTML(videoID: "abc12345678")
        #expect(html.contains("youtube-embed-container"))
        // Click-to-play facade: a thumbnail poster + play button shown before the iframe loads.
        #expect(html.contains("youtube-facade"))
        #expect(html.contains("https://i.ytimg.com/vi/abc12345678/hqdefault.jpg"))
        #expect(html.contains("youtube-play"))
        // The player markup is stashed in data-embed (quotes entity-escaped) and swapped in on tap.
        #expect(html.contains("https://www.youtube-nocookie.com/embed/abc12345678?"))
        #expect(html.contains("autoplay=1"))
        #expect(html.contains("rel=0"))
        #expect(html.contains("modestbranding=1"))
        #expect(html.contains("playsinline=1"))
        #expect(html.contains("origin=\(ReaderWeb.baseOrigin)"))
        #expect(html.contains("allow=&quot;accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share&quot;"))
    }

    @Test func rewriteEmbedsReplacesYouTubeIframe() throws {
        let doc = try SwiftSoup.parse("<iframe src=\"https://www.youtube.com/embed/abc12345678\"></iframe>")
        try EmbedRewriter.rewriteEmbeds(in: doc)
        let html = try doc.body()!.html()
        #expect(html.contains("youtube-nocookie.com/embed/abc12345678"))
        #expect(html.contains("youtube-embed-container"))
    }

    @Test func giphyGIFURLFromEmbedAndWatchURLs() {
        #expect(EmbedRewriter.giphyGIFURL(from: "https://giphy.com/embed/l0MYt5jPR6QX5pnqM")
            == "https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif")
        // A watch URL carries a human slug; the id is the final dash-delimited segment.
        #expect(EmbedRewriter.giphyGIFURL(from: "https://giphy.com/gifs/funny-cat-l0MYt5jPR6QX5pnqM")
            == "https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif")
        #expect(EmbedRewriter.giphyGIFURL(from: "https://www.youtube.com/embed/abc12345678") == nil)
    }

    @Test func rewriteEmbedsReplacesGiphyIframeWithImage() throws {
        let doc = try SwiftSoup.parse("<iframe src=\"https://giphy.com/embed/l0MYt5jPR6QX5pnqM\"></iframe>")
        try EmbedRewriter.rewriteEmbeds(in: doc)
        let html = try doc.body()!.html()
        #expect(html.contains("<img"))
        #expect(html.contains("media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif"))
        #expect(!html.contains("<iframe"))
    }

    // WordPress' "Embed Privacy" plugin (e.g. Caschy's Blog) ships a consent gate instead of a live
    // iframe — the real player is in a stripped <script>, so only the "open directly" footer link and
    // the consent boilerplate survive. Recover the video from that footer link and build the facade.
    @Test func rewriteEmbedsRecoversEmbedPrivacyYouTubeGate() throws {
        let gate = """
        <div class="embed-privacy-container is-disabled embed-youtube" data-embed-provider="youtube">
          <div class="embed-privacy-inner">
            <p>Hier klicken, um den Inhalt von YouTube anzuzeigen.
            Erfahre mehr in der <a href="https://policies.google.com/privacy?hl=de">Datenschutzerklärung von YouTube</a>.</p>
            <p class="embed-privacy-input-wrapper"><label>Inhalt von YouTube immer anzeigen</label></p>
          </div>
          <div class="embed-privacy-footer"><span class="embed-privacy-url">
            <a target="_blank" href="https://www.youtube.com/watch?v=XNbc2HhL7J4">„Claude Cowork“ direkt öffnen</a>
          </span></div>
        </div>
        """
        let doc = try SwiftSoup.parse(gate)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        let html = try doc.body()!.html()
        // The consent gate is gone and a YouTube facade for the recovered video id took its place.
        #expect(html.contains("youtube-embed-container"))
        #expect(html.contains("youtube-nocookie.com/embed/XNbc2HhL7J4"))
        #expect(!html.contains("embed-privacy-container"))
        #expect(!html.contains("Hier klicken"))
        #expect(!html.contains("Inhalt von YouTube immer anzeigen"))
        // The privacy-policy link inside the gate must not be mistaken for the video URL.
        #expect(!html.contains("policies.google.com"))
    }

    // A consent gate with no recoverable video URL is dropped so its boilerplate doesn't leak in.
    @Test func rewriteEmbedsDropsUnrecoverableEmbedPrivacyGate() throws {
        let gate = """
        <div class="embed-privacy-container is-disabled">
          <p>Hier klicken, um den Inhalt von X anzuzeigen.</p>
        </div>
        """
        let doc = try SwiftSoup.parse(gate)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        let html = try doc.body()!.html()
        #expect(!html.contains("embed-privacy-container"))
        #expect(!html.contains("Hier klicken"))
    }
}
