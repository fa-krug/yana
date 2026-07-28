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

    // The player page is loaded as the **top-level** document, so the provider is first-party and
    // can keep its own cookies (consent choice, quality) between plays. An `origin=` parameter names
    // the *embedder* of an <iframe>; carrying one into a first-party load both misstates the origin
    // and marks the player as embedded, which is exactly the arrangement whose cookies WebKit drops.
    @Test func youTubePlayerURLCarriesNoEmbedderOrigin() {
        let e = embed(.youtube, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let url = ReaderVideoPlayerViewController.playerURL(for: e)
        #expect(url?.absoluteString.contains("origin=") == false)
    }

    // The Dailymotion player's "we use required trackers" notice is suppressed through the player's
    // OWN mechanism: it records that it already showed the notice in `dmp_consent_fallback_shown` and
    // skips it while that flag is live, so pre-seeding the flag means the notice never renders. Keyed
    // on the player's host, because only Dailymotion's player reads that key.
    @Test func dailymotionPlayerSuppressesTheTrackerNotice() {
        let e = embed(.dailymotion, url: "https://www.dailymotion.com/video/xasx4q2")
        let url = ReaderVideoPlayerViewController.playerURL(for: e)
        #expect(url != nil)
        let script = ReaderVideoPlayerViewController.noticeSuppressionScript(for: url!)
        #expect(script?.contains("dmp_consent_fallback_shown") == true)
    }

    // YouTube's player does not show that notice and does not read that key, so it gets no script.
    @Test func youTubePlayerGetsNoSuppressionScript() {
        let e = embed(.youtube, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let url = ReaderVideoPlayerViewController.playerURL(for: e)
        #expect(ReaderVideoPlayerViewController.noticeSuppressionScript(for: url!) == nil)
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
