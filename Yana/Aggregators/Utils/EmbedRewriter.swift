import Foundation
import SwiftSoup

/// Rewrites in-content video embeds to the exact markup the server's proxy served
/// (core/views/default.py), but pointing directly at the provider (no server hop).
enum EmbedRewriter {
    // Compiled once and reused instead of recompiling 5 patterns per call.
    private static let youTubePatterns: [NSRegularExpression] = {
        [
            #"youtu\.be/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/watch\?\S*?[?&]?v=([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/embed/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/v/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/shorts/([A-Za-z0-9_-]{11,})"#,
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func extractYouTubeID(from url: String) -> String? {
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        for regex in youTubePatterns {
            guard let match = regex.firstMatch(in: url, range: range), match.numberOfRanges >= 2,
                  let captured = Range(match.range(at: 1), in: url) else { continue }
            return String(url[captured])
        }
        return nil
    }

    /// A click-to-play facade rather than a bare live iframe: the privacy-mode (`-nocookie`) player
    /// renders a black box with only a play button until interacted with — no poster — so we paint
    /// the video's own thumbnail as a proper 16:9 preview and swap in the autoplaying iframe on tap.
    /// The facade is a `<div>` (not an `<a>`), so the reader's link-tap interceptor ignores it.
    /// `videoID` is regex-validated (`[A-Za-z0-9_-]`), so it is safe to interpolate into attributes.
    static func youTubeEmbedHTML(videoID: String) -> String {
        let params = "autoplay=1&loop=0&mute=0&controls=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1&origin=\(ReaderWeb.baseOrigin)"
        let src = "https://www.youtube-nocookie.com/embed/\(videoID)?\(params)"
        let allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
        let iframe = "<iframe src=\"\(src)\" width=\"560\" height=\"315\" "
            + "allowfullscreen allow=\"\(allow)\" referrerpolicy=\"strict-origin-when-cross-origin\"></iframe>"
        // Stash the player markup in an attribute (quotes entity-escaped) and replace the facade with
        // it on tap. getAttribute returns the decoded HTML, so outerHTML rebuilds the iframe in place.
        let embedAttr = iframe.replacingOccurrences(of: "\"", with: "&quot;")
        let thumb = "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
        // The poster is a real <img> (not a CSS background) so the scraper cleaner's
        // remove-empty-elements pass keeps the facade — it counts img/iframe/video as content.
        return "<div class=\"youtube-embed-container\">"
            + "<div class=\"youtube-facade\" role=\"button\" aria-label=\"Play video\" "
            + "onclick=\"this.outerHTML=this.getAttribute('data-embed')\" data-embed=\"\(embedAttr)\">"
            + "<img class=\"youtube-poster\" src=\"\(thumb)\" alt=\"\" loading=\"lazy\" />"
            + "<div class=\"youtube-play\" aria-hidden=\"true\"></div></div></div>"
    }

    /// Click-to-play facade for Dailymotion, mirroring `youTubeEmbedHTML`: the video's own thumbnail
    /// is painted as a 16:9 preview and the autoplaying player iframe is swapped in on tap (the tap is
    /// the user gesture that unblocks sound). The facade is a `<div>` (not an `<a>`), so the reader's
    /// link-tap interceptor ignores it. `videoID` is sanitized to `[A-Za-z0-9]` (Dailymotion IDs are
    /// alphanumeric), so it is safe to interpolate into attributes.
    static func dailymotionEmbedHTML(videoID rawID: String) -> String {
        let videoID = rawID.filter { $0.isLetter || $0.isNumber }
        let src = "https://geo.dailymotion.com/player.html?video=\(videoID)&autoplay=1"
        let allow = "autoplay; fullscreen; picture-in-picture; web-share"
        let iframe = "<iframe src=\"\(src)\" width=\"560\" height=\"315\" "
            + "allowfullscreen allow=\"\(allow)\" referrerpolicy=\"strict-origin-when-cross-origin\"></iframe>"
        // Stash the player markup in an attribute (quotes entity-escaped) and replace the facade with
        // it on tap. getAttribute returns the decoded HTML, so outerHTML rebuilds the iframe in place.
        let embedAttr = iframe.replacingOccurrences(of: "\"", with: "&quot;")
        let thumb = "https://www.dailymotion.com/thumbnail/video/\(videoID)"
        // The poster is a real <img> (not a CSS background) so the scraper cleaner's
        // remove-empty-elements pass keeps the facade — it counts img/iframe/video as content.
        return "<div class=\"dailymotion-embed-container\">"
            + "<div class=\"dailymotion-facade\" role=\"button\" aria-label=\"Play video\" "
            + "onclick=\"this.outerHTML=this.getAttribute('data-embed')\" data-embed=\"\(embedAttr)\">"
            + "<img class=\"dailymotion-poster\" src=\"\(thumb)\" alt=\"\" loading=\"lazy\" />"
            + "<div class=\"dailymotion-play\" aria-hidden=\"true\"></div></div></div>"
    }

    static func rewriteEmbeds(in doc: Document) throws {
        for iframe in try doc.select("iframe") {
            let src = try iframe.attr("src")
            if let id = extractYouTubeID(from: src) {
                let replacement = try SwiftSoup.parseBodyFragment(youTubeEmbedHTML(videoID: id)).body()!.child(0)
                try iframe.replaceWith(replacement)
            }
        }
    }

    /// Twitter/X via fxtwitter (direct API). Returns blockquote HTML or nil.
    static func tweetEmbedHTML(for url: String) async -> String? {
        guard let idRange = url.range(of: #"status/(\d+)"#, options: .regularExpression) else { return nil }
        let id = String(url[idRange]).replacingOccurrences(of: "status/", with: "")
        guard let apiURL = URL(string: "https://api.fxtwitter.com/status/\(id)") else { return nil }
        var req = URLRequest(url: apiURL)
        req.setValue("Yana/1.0", forHTTPHeaderField: "User-Agent")
        guard let data = try? await HTTPClient.fetchJSON(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tweet = json["tweet"] as? [String: Any] else { return nil }
        let text = escapeHTML(tweet["text"] as? String ?? "")
        let author = escapeHTML((tweet["author"] as? [String: Any])?["screen_name"] as? String ?? "")
        let style = "border-left: 3px solid #1d9bf0; padding: 12px 16px; margin: 1em 0; background: #f7f9fa;"
        return "<blockquote style=\"\(style)\"><p><strong>@\(author)</strong> · "
            + "<a href=\"\(url)\">View on X</a></p><p>\(text)</p></blockquote>"
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
