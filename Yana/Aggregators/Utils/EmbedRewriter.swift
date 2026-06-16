import Foundation
import SwiftSoup

/// Rewrites in-content video embeds to the exact markup the server's proxy served
/// (core/views/default.py), but pointing directly at the provider (no server hop).
enum EmbedRewriter {
    static func extractYouTubeID(from url: String) -> String? {
        let patterns = [
            #"youtu\.be/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/watch\?\S*?[?&]?v=([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/embed/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/v/([A-Za-z0-9_-]{11,})"#,
            #"youtube\.com/shorts/([A-Za-z0-9_-]{11,})"#,
        ]
        for p in patterns {
            if let r = url.range(of: p, options: .regularExpression) {
                let match = String(url[r])
                if let idRange = match.range(of: #"[A-Za-z0-9_-]{11,}$"#, options: .regularExpression) {
                    return String(match[idRange])
                }
            }
        }
        return nil
    }

    static func youTubeEmbedHTML(videoID: String) -> String {
        let params = "autoplay=0&loop=0&mute=0&controls=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1&origin=\(ReaderWeb.baseOrigin)"
        let src = "https://www.youtube-nocookie.com/embed/\(videoID)?\(params)"
        return """
        <div class="youtube-embed-container"><iframe src="\(src)" width="560" height="315" allowfullscreen allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin"></iframe></div>
        """
    }

    static func dailymotionEmbedHTML(videoID: String) -> String {
        let src = "https://geo.dailymotion.com/player.html?video=\(videoID)"
        return """
        <div class="dailymotion-embed-container"><iframe src="\(src)" width="560" height="315" allowfullscreen allow="autoplay; web-share" referrerpolicy="strict-origin-when-cross-origin"></iframe></div>
        """
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
        return """
        <blockquote style="border-left: 3px solid #1d9bf0; padding: 12px 16px; margin: 1em 0; background: #f7f9fa;"><p><strong>@\(author)</strong> · <a href="\(url)">View on X</a></p><p>\(text)</p></blockquote>
        """
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
