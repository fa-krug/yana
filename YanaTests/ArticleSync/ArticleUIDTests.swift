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

    @Test("An over-long UID collapses to a CloudKit-valid record name")
    func overLongCollapses() {
        // A long feed URL plus a long article permalink: the natural concatenation blows past
        // CloudKit's 255-unit record-name limit, which used to raise an uncatchable CKException.
        let uid = ArticleUID.make(
            feedIdentifier: "https://feed.example/" + String(repeating: "a", count: 150),
            aggregatorType: "feedContent",
            articleIdentifier: "https://feed.example/post/" + String(repeating: "b", count: 150),
            date: Date(timeIntervalSince1970: 1000), title: "Hello"
        )
        #expect(uid.utf16.count <= ArticleUID.recordNameLimit)
        #expect(!uid.isEmpty)
    }

    @Test("Collapsing is deterministic and keeps distinct articles distinct")
    func collapseIsDeterministicAndUnique() {
        func longUID(post: String) -> String {
            ArticleUID.make(
                feedIdentifier: "https://feed.example/" + String(repeating: "a", count: 150),
                aggregatorType: "feedContent",
                articleIdentifier: "https://feed.example/" + String(repeating: "b", count: 150) + post,
                date: Date(timeIntervalSince1970: 1000), title: "Hello"
            )
        }
        // Same inputs → same UID, so every device agrees on the record name.
        #expect(longUID(post: "/1") == longUID(post: "/1"))
        // Different articles that share a long prefix must NOT collapse together — truncating
        // instead of hashing would alias them onto one record and lose an article.
        #expect(longUID(post: "/1") != longUID(post: "/2"))
    }

    @Test("A UID over the limit in UTF-16 units collapses even when its character count fits")
    func collapseCountsUTF16Units() {
        // CloudKit measures the record name in UTF-16 code units, so 130 emoji (130 characters,
        // 260 units) is already too long.
        let uid = ArticleUID.make(
            feedIdentifier: String(repeating: "😀", count: 130), aggregatorType: "feedContent",
            articleIdentifier: "a-1", date: Date(timeIntervalSince1970: 1000), title: "Hello"
        )
        #expect(uid.utf16.count <= ArticleUID.recordNameLimit)
    }

    @Test("A UID that already fits is left byte-identical")
    func shortUIDUnchanged() {
        // Existing synced records must keep their identity, so anything within the limit is
        // returned untouched rather than hashed.
        let uid = ArticleUID.make(
            feedIdentifier: "https://feed.example/rss", aggregatorType: "feedContent",
            articleIdentifier: "https://feed.example/post/1",
            date: Date(timeIntervalSince1970: 1000), title: "Hello"
        )
        #expect(uid == "https://feed.example/rss|feedContent|https://feed.example/post/1")
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
