import Testing
@testable import Yana

@Suite("Block.imageHashes")
struct BlockImageHashesTests {

    @Test func collectsAnImageBlockHash() {
        let blocks: [Block] = [.image(ref: "yana-img://abc", caption: [])]
        #expect(Block.imageHashes(in: blocks) == ["abc"])
    }

    @Test func collectsAnEmbedThumbnailHash() {
        let blocks: [Block] = [.embed(Embed(provider: .video, thumbnailRef: "yana-img://poster",
                                             externalURL: "https://example.test/v.mp4", title: nil))]
        #expect(Block.imageHashes(in: blocks) == ["poster"])
    }

    @Test func recursesIntoListsAndBlockquotes() {
        let blocks: [Block] = [
            .list(ordered: false, items: [[.image(ref: "yana-img://in-list", caption: [])]]),
            .blockquote([.image(ref: "yana-img://in-quote", caption: [])]),
        ]
        #expect(Block.imageHashes(in: blocks) == ["in-list", "in-quote"])
    }

    @Test func ignoresRemoteURLRefsAndEmbedsWithNoThumbnail() {
        let blocks: [Block] = [
            .image(ref: "https://example.test/remote.jpg", caption: []),
            .embed(Embed(provider: .tweet, thumbnailRef: nil, externalURL: "https://example.test/tweet", title: nil)),
        ]
        #expect(Block.imageHashes(in: blocks).isEmpty)
    }

    @Test func ignoresNonImageBearingBlocks() {
        let blocks: [Block] = [
            .paragraph([]), .heading(level: 1, runs: []), .codeBlock(text: "x", language: nil), .divider,
        ]
        #expect(Block.imageHashes(in: blocks).isEmpty)
    }
}
