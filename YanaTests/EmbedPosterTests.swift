import Testing
import UIKit
@testable import Yana

/// A video embed whose poster can't be shown -- a private/deleted YouTube video has no publicly
/// fetchable thumbnail, so `yana-server`'s `localizeThumbnail` stores an empty ref and the wire
/// carries `thumbnailRef: null` -- used to render as a flat black 16:9 rectangle with a lone play
/// glyph, which reads as a failed image load rather than as "there is no preview for this."
/// `EmbedPoster` is the placeholder artwork that replaced it.
@Suite("EmbedPoster")
struct EmbedPosterTests {

    /// A glyph name that doesn't resolve draws nothing at all, which is the exact "looks broken"
    /// state this placeholder exists to remove. Driven off `allCases` so a provider added later
    /// can't quietly ship without artwork.
    @Test(arguments: Embed.Provider.allCases)
    func everyProviderHasAGlyphThatResolves(provider: Embed.Provider) {
        let name = EmbedPoster.glyph(for: provider)
        #expect(!name.isEmpty)
        #expect(UIImage(systemName: name) != nil,
                "\(provider.rawValue) glyph \"\(name)\" is not an SF Symbol")
    }

    @Test func aMissingThumbnailNeedsThePlaceholder() {
        let embed = Embed(provider: .youtube, thumbnailRef: nil,
                          externalURL: "https://www.youtube.com/watch?v=x", title: nil)
        #expect(EmbedPoster.needsPlaceholder(for: embed))
    }

    /// The wire nulls an empty ref (`orNull` in the server's `encodeBlock`), but a locally-authored
    /// block -- a debug/screenshot fixture, a future decode path -- can still carry `""`, and an
    /// empty ref resolves to no image just the same.
    @Test func anEmptyThumbnailRefNeedsThePlaceholderToo() {
        let embed = Embed(provider: .dailymotion, thumbnailRef: "",
                          externalURL: "https://www.dailymotion.com/video/x1", title: nil)
        #expect(EmbedPoster.needsPlaceholder(for: embed))
    }

    @Test func arealThumbnailDoesNotNeedThePlaceholder() {
        let embed = Embed(provider: .video, thumbnailRef: "yana-img://poster",
                          externalURL: "https://v.redd.it/x.m3u8", title: nil)
        #expect(!EmbedPoster.needsPlaceholder(for: embed))
    }
}
