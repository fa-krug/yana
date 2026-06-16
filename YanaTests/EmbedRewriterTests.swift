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
        #expect(html.contains("https://www.youtube-nocookie.com/embed/abc12345678?"))
        #expect(html.contains("rel=0"))
        #expect(html.contains("modestbranding=1"))
        #expect(html.contains("playsinline=1"))
        #expect(html.contains("origin=\(ReaderWeb.baseOrigin)"))
        #expect(html.contains("allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share\""))
    }

    @Test func rewriteEmbedsReplacesYouTubeIframe() throws {
        let doc = try SwiftSoup.parse("<iframe src=\"https://www.youtube.com/embed/abc12345678\"></iframe>")
        try EmbedRewriter.rewriteEmbeds(in: doc)
        let html = try doc.body()!.html()
        #expect(html.contains("youtube-nocookie.com/embed/abc12345678"))
        #expect(html.contains("youtube-embed-container"))
    }
}
