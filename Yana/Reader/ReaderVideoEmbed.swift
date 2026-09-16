import Foundation

/// The **pure** half of `ReaderVideoPlayerViewController`: everything that decides *what* to play
/// and *how the provider insists on being loaded*, with no view, no window and no platform in it.
///
/// It lives in its own file, as an extension, because the hosting half is forked
/// (`ReaderVideoPlayerViewController.swift` is `#if os(iOS)`, `…MacOS.swift` is `#if os(macOS)`)
/// while this half must be identical on both — `ArticleBlockView.isPlayableVideo` calls
/// `playerURL(for:)` from the shared body renderer, so it has to resolve on macOS too, and
/// `ReaderVideoPlayerTests` pins these five functions once rather than per platform. Each platform
/// declares the class; this extension adds the same statics to whichever one is being compiled.
///
/// **The YouTube / everything-else split below is load-bearing, and the two branches must not be
/// unified.** See `requiresEmbedderContext(_:)`.
extension ReaderVideoPlayerViewController {
    /// Maps an embed to its inline-playable embed-player URL, or `nil` when it isn't a video we can
    /// play in place.
    static func playerURL(for embed: Embed) -> URL? {
        switch embed.provider {
        case .youtube:
            guard let id = extractYouTubeID(from: embed.externalURL) else { return nil }
            // `origin=` names the embedder of the iframe this player is loaded into, and must match
            // the base URL of the wrapper page (see `html(embedURL:)`). It is not optional here:
            // without an embedder the `/embed/` endpoint refuses to configure the player (error 153).
            let params = "autoplay=1&playsinline=1&controls=1&rel=0&modestbranding=1&fs=1&origin=\(ReaderWeb.baseOrigin)"
            return URL(string: "https://www.youtube-nocookie.com/embed/\(id)?\(params)")
        case .dailymotion:
            guard let id = dailymotionID(from: embed.externalURL) else { return nil }
            return URL(string: "https://geo.dailymotion.com/player.html?video=\(id)&autoplay=1")
        case .video:
            // A direct stream (HLS/MP4): the "player URL" is the stream itself, played via AVPlayer.
            return URL(string: embed.externalURL)
        case .tweet, .generic:
            return nil
        }
    }

    /// Whether this player has to be loaded *inside an iframe* on a wrapper page rather than as the
    /// top-level document.
    ///
    /// True only for YouTube. Its `/embed/` endpoint exists to be embedded and validates that it is:
    /// a top-level navigation sends no `Referer` and names no embedder, and the player answers with
    /// **"Error 153 — the video player configuration failed"** instead of playing. So YouTube keeps the
    /// wrapper page, whose base URL supplies the `Referer` that matches the `origin=` parameter
    /// `playerURL(for:)` puts on the player URL.
    ///
    /// Every other provider loads top-level, which is strictly better where it works: the player is
    /// then first-party and may keep its own cookies and DOM storage, which is what lets Dailymotion
    /// remember it already showed its tracker notice (see `noticeSuppressionScript(for:)`). YouTube
    /// gives that up, but has nothing to remember — its player is `-nocookie` privacy mode and starts
    /// from a clean slate by design.
    static func requiresEmbedderContext(_ playerURL: URL) -> Bool {
        guard let host = playerURL.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    /// Script that suppresses the Dailymotion player's built-in "we use required trackers" notice —
    /// the banner that used to greet every single playback — or `nil` for players that never show it.
    ///
    /// There is no player parameter for this. The full documented runtime parameter set is
    /// `video`/`playlist`/`customConfig`/`scaleMode`/`startTime`/`loop`/`autoplay`, and Dailymotion's
    /// only supported route is for the embedder to run a TCF 2 certified CMP, which the player then
    /// defers to — not something this app should do, since it would mean asserting tracking consent on
    /// the user's behalf.
    ///
    /// So this uses the player's own bookkeeping instead of touching its DOM: the player records that
    /// it already showed the notice in `localStorage` under `dmp_consent_fallback_shown` (observed
    /// TTL: 30 days) and skips the notice while that flag is live. Pre-seeding the flag is therefore
    /// far steadier than hiding `.notification_dialog` would be — it cannot hide the wrong element,
    /// and if Dailymotion ever renames the key the only consequence is that the notice appears again,
    /// exactly as it does today. Note this suppresses the *disclosure*, not the trackers themselves;
    /// per Dailymotion's cookie policy only essential trackers run while that banner is the fallback.
    ///
    /// This only works because the player is the top-level document (see the type comment): DOM
    /// storage is blocked in the cross-site iframe it used to live in, which is precisely why the
    /// player could never remember the notice and re-showed it on every play.
    static func noticeSuppressionScript(for playerURL: URL) -> String? {
        guard let host = playerURL.host?.lowercased(),
              host == "dailymotion.com" || host.hasSuffix(".dailymotion.com") else { return nil }
        return """
        try {
          var ttl = 30 * 24 * 60 * 60 * 1000;
          localStorage.setItem('dmp_consent_fallback_shown',
            JSON.stringify({ expires: Date.now() + ttl, data: true }));
        } catch (e) {}
        """
    }

    private static func dailymotionID(from url: String) -> String? {
        guard let range = url.range(of: #"video/([A-Za-z0-9]+)"#, options: .regularExpression) else { return nil }
        return String(url[range]).replacingOccurrences(of: "video/", with: "")
    }

    // Compiled once and reused instead of recompiling 5 patterns per call. Relocated from the
    // (now-deleted) aggregation-time `EmbedRewriter` -- this is the only half of that file still
    // needed post-rework, since embed HTML rewriting itself now happens server-side.
    private static let youTubePatterns: [NSRegularExpression] = {
        [
            #"youtu\.be/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/watch\?\S*?[?&]?v=([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/embed/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/v/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/shorts/([A-Za-z0-9_-]{11,})"#,
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static func extractYouTubeID(from url: String) -> String? {
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        for regex in youTubePatterns {
            guard let match = regex.firstMatch(in: url, range: range), match.numberOfRanges >= 2,
                  let captured = Range(match.range(at: 1), in: url) else { continue }
            return String(url[captured])
        }
        return nil
    }


    /// A self-contained page that paints the embed player edge-to-edge on black, used for the
    /// providers that insist on being embedded (`requiresEmbedderContext(_:)`). Its base URL is
    /// `ReaderWeb.baseOrigin`, so the iframe's `Referer` matches the `origin=` the player URL carries.
    /// The iframe carries the same `allow`/`allowfullscreen` capabilities the providers expect for
    /// autoplay + fullscreen.
    static func html(embedURL: URL) -> String {
        let src = embedURL.absoluteString
        let allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen"
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <style>
        html,body{margin:0;padding:0;height:100%;width:100%;background:#000;overflow:hidden}
        .wrap{position:fixed;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;justify-content:center}
        iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}
        </style></head>
        <body><div class="wrap">
        <iframe src="\(src)" allow="\(allow)" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </div></body></html>
        """
    }
}
