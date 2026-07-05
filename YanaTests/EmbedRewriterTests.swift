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
}
