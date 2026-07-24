import Foundation
import Testing
@testable import Yana

@Suite("ArticleUID")
struct ArticleUIDTests {
    @Test("UID uses the triple when articleIdentifier is present")
    func triple() {
        let uid = ArticleUID.make(
            feedIdentifier: "https://feed.example/rss",
            aggregatorType: "feedContent",
            articleIdentifier: "https://feed.example/post/1",
            date: Date(timeIntervalSince1970: 1000),
            title: "Hello"
        )
        #expect(uid == "https://feed.example/rss|feedContent|https://feed.example/post/1")
    }

    @Test("UID falls back to a date+title hash when articleIdentifier is empty")
    func fallback() {
        let uid = ArticleUID.make(
            feedIdentifier: "f", aggregatorType: "feedContent",
            articleIdentifier: "", date: Date(timeIntervalSince1970: 1000), title: "Hello"
        )
        #expect(uid.hasPrefix("f|feedContent|"))
        // Deterministic: same inputs → same UID.
        let again = ArticleUID.make(
            feedIdentifier: "f", aggregatorType: "feedContent",
            articleIdentifier: "", date: Date(timeIntervalSince1970: 1000), title: "Hello"
        )
        #expect(uid == again)
        // The fallback segment is not empty.
        #expect(uid != "f|feedContent|")
    }

    @Test("Image hashes are collected from nested blocks and deduped")
    func imageHashes() {
        let blocks: [Block] = [
            .image(ref: "yana-img://aaa", caption: []),
            .blockquote([.image(ref: "yana-img://bbb", caption: [])]),
            .list(ordered: false, items: [[.image(ref: "yana-img://aaa", caption: [])]]),
            .embed(Embed(provider: .video, thumbnailRef: "yana-img://ccc", externalURL: "x", title: nil)),
            .paragraph([InlineRun(text: "no image")])
        ]
        let hashes = Set(ArticleImageRefs.hashes(in: blocks))
        #expect(hashes == ["aaa", "bbb", "ccc"])
    }

    @Test("hash(from:) only unwraps the yana-img scheme")
    func hashFrom() {
        #expect(ArticleImageRefs.hash(from: "yana-img://deadbeef") == "deadbeef")
        #expect(ArticleImageRefs.hash(from: "https://remote/x.jpg") == nil)
    }
}
