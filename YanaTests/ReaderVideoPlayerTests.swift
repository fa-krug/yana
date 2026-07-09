import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ReaderVideoPlayer")
struct ReaderVideoPlayerTests {
    private func embed(_ provider: Embed.Provider, url: String) -> Embed {
        Embed(provider: provider, thumbnailRef: nil, externalURL: url, title: nil)
    }

    // A direct-stream (.video) embed is inline-playable: its player URL is the stream URL itself,
    // so EmbedCardView shows the play button and the poster taps into the AVPlayer.
    @Test func directVideoIsPlayable() {
        let e = embed(.video, url: "https://v.redd.it/abc/HLSPlaylist.m3u8")
        #expect(ReaderVideoPlayerViewController.playerURL(for: e)?.absoluteString
                == "https://v.redd.it/abc/HLSPlaylist.m3u8")
    }

    // A YouTube embed still maps to its privacy-mode iframe player.
    @Test func youTubeMapsToNoCookiePlayer() {
        let e = embed(.youtube, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let url = ReaderVideoPlayerViewController.playerURL(for: e)
        #expect(url?.absoluteString.contains("youtube-nocookie.com/embed/dQw4w9WgXcQ") == true)
    }

    // Tweet/generic embeds are not inline-playable (they open externally).
    @Test func tweetIsNotPlayable() {
        #expect(ReaderVideoPlayerViewController.playerURL(for: embed(.tweet, url: "https://x.com/a/status/1")) == nil)
    }

    // A .video embed produces a presentable player controller.
    @Test func makeBuildsPlayerForDirectVideo() {
        let e = embed(.video, url: "https://v.redd.it/abc/HLSPlaylist.m3u8")
        #expect(ReaderVideoPlayerViewController.make(for: e) != nil)
    }
}
