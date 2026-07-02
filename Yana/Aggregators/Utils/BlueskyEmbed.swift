import Foundation

/// Bluesky (bsky.app) post embed utilities.
///
/// Ports `core/aggregators/utils/bluesky.py` from the Yana server.
/// Provides URL detection, post-info extraction, post fetching, and
/// rich blockquote HTML generation for inline embeds.
enum BlueskyEmbed {

    // MARK: - Public API base

    static let apiBase = "https://public.api.bsky.app"

    // MARK: - URL detection

    /// Returns true if the URL belongs to bsky.app (or staging.bsky.app).
    static func isBlueskyURL(_ url: String) -> Bool {
        !url.isEmpty && url.contains("bsky.app")
    }

    // MARK: - Post info extraction

    /// Extracts `(actor, rkey)` from a Bluesky post URL.
    /// Pattern: `/profile/{handle_or_did}/post/{rkey}`
    static func extractPostInfo(from url: String) -> (actor: String, rkey: String)? {
        guard !url.isEmpty else { return nil }
        guard let range = url.range(of: #"/profile/([^/?#]+)/post/([^/?#]+)"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(url[range])
        // Split on "/" to pull out the actor and rkey.
        let parts = matched.split(separator: "/", omittingEmptySubsequences: true)
        // parts: ["profile", actor, "post", rkey]
        guard parts.count >= 4 else { return nil }
        let actor = String(parts[1])
        let rkey  = String(parts[3])
        return (actor, rkey)
    }

    // MARK: - Resolve handle → DID

    /// Resolves a Bluesky handle to a DID via the public API.
    /// If `actor` already starts with `did:`, it is returned as-is.
    ///
    /// - Parameter fetchJSON: Injected network call (defaults to `HTTPClient.fetchJSON`).
    static func resolveDID(
        actor: String,
        fetchJSON: @Sendable (URLRequest) async throws -> Data = { try await HTTPClient.fetchJSON($0) }
    ) async -> String? {
        guard !actor.isEmpty else { return nil }
        if actor.hasPrefix("did:") { return actor }

        guard let url = URL(string: "\(apiBase)/xrpc/com.atproto.identity.resolveHandle"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "handle", value: actor)]
        guard let resolveURL = components.url else { return nil }
        var req = URLRequest(url: resolveURL)
        req.setValue("Yana/1.0", forHTTPHeaderField: "User-Agent")

        guard let data = try? await fetchJSON(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let did = json["did"] as? String else { return nil }
        return did
    }

    // MARK: - Fetch post

    /// Fetches a single post from the public Bluesky API.
    ///
    /// - Parameter fetchJSON: Injected network call.
    static func fetchPost(
        actor: String,
        rkey: String,
        fetchJSON: @Sendable (URLRequest) async throws -> Data = { try await HTTPClient.fetchJSON($0) }
    ) async -> [String: Any]? {
        guard !actor.isEmpty, !rkey.isEmpty else { return nil }

        guard let did = await resolveDID(actor: actor, fetchJSON: fetchJSON) else { return nil }
        let atURI = "at://\(did)/app.bsky.feed.post/\(rkey)"

        guard let url = URL(string: "\(apiBase)/xrpc/app.bsky.feed.getPosts"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "uris", value: atURI)]
        guard let getPosts = components.url else { return nil }
        var req = URLRequest(url: getPosts)
        req.setValue("Yana/1.0", forHTTPHeaderField: "User-Agent")

        guard let data = try? await fetchJSON(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let posts = json["posts"] as? [[String: Any]],
              let first = posts.first else { return nil }
        return first
    }

    // MARK: - Image extraction

    /// Extracts fullsize (falling back to thumb) image URLs from a post dict.
    /// Handles `app.bsky.embed.images#view` and `app.bsky.embed.recordWithMedia#view`.
    static func extractImageURLs(from post: [String: Any]) -> [String] {
        guard var embed = post["embed"] as? [String: Any] else { return [] }
        let embedType = embed["$type"] as? String ?? ""
        if embedType.contains("recordWithMedia"), let media = embed["media"] as? [String: Any] {
            embed = media
        }
        guard let images = embed["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { img in
            (img["fullsize"] as? String) ?? (img["thumb"] as? String)
        }
    }

    // MARK: - HTML building

    /// Builds a rich blockquote HTML embed for a Bluesky post URL.
    /// Returns nil on any network or parse failure (graceful fallback).
    ///
    /// - Parameter fetchJSON: Injected network call for tests.
    static func buildEmbedHTML(
        for url: String,
        fetchJSON: @Sendable (URLRequest) async throws -> Data = { try await HTTPClient.fetchJSON($0) }
    ) async -> String? {
        guard let (actor, rkey) = extractPostInfo(from: url) else { return nil }

        guard let post = await fetchPost(actor: actor, rkey: rkey, fetchJSON: fetchJSON) else { return nil }

        let record      = post["record"]  as? [String: Any] ?? [:]
        let text        = record["text"]  as? String ?? ""
        let author      = post["author"]  as? [String: Any] ?? [:]
        let displayName = author["displayName"] as? String ?? ""
        let handle      = author["handle"]      as? String ?? ""
        let likes       = post["likeCount"]     as? Int ?? 0
        let reposts     = post["repostCount"]   as? Int ?? 0
        let replies     = post["replyCount"]    as? Int ?? 0
        let createdAt   = record["createdAt"]   as? String ?? ""

        // Strip tracking params.
        let cleanURL = url.split(separator: "?").first.map(String.init) ?? url

        var parts: [String] = []
        parts.append(
            "<blockquote style=\"border-left: 3px solid #0085ff; padding: 12px 16px;"
            + " margin: 1em 0; background: #f7f9fa;\">"
        )

        // Author line.
        let authorDisplay = displayName.isEmpty ? (handle.isEmpty ? "" : "@\(handle)") : displayName
        let handleSuffix  = (!displayName.isEmpty && !handle.isEmpty) ? " (@\(handle))" : ""
        parts.append(
            "<p style=\"margin: 0 0 8px 0;\">"
            + "<strong>\(escapeHTML(authorDisplay))</strong>\(escapeHTML(handleSuffix)) · "
            + "<a href=\"\(cleanURL)\" target=\"_blank\" rel=\"noopener\">\(String(localized: "View on Bluesky"))</a>"
            + "</p>"
        )

        // Post text.
        if !text.isEmpty {
            parts.append("<p style=\"margin: 0 0 8px 0; white-space: pre-wrap;\">\(escapeHTML(text))</p>")
        }

        // Images.
        for imgURL in extractImageURLs(from: post) {
            parts.append(
                "<p><img src=\"\(imgURL)\" alt=\"Bluesky image\""
                + " style=\"max-width: 100%; border-radius: 8px;\"></p>"
            )
        }

        // Engagement stats + date.
        var statParts: [String] = []
        if likes   > 0 { statParts.append("&#9829; \(formatCount(likes))") }
        if reposts > 0 { statParts.append("&#128257; \(formatCount(reposts))") }
        if replies > 0 { statParts.append("&#128172; \(formatCount(replies))") }
        if let date = formatDate(createdAt) { statParts.append(date) }
        if !statParts.isEmpty {
            parts.append(
                "<p style=\"margin: 0; color: #536471; font-size: 0.9em;\">"
                + statParts.joined(separator: " · ")
                + "</p>"
            )
        }

        parts.append("</blockquote>")
        return parts.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    static func formatDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            let out = DateFormatter()
            out.locale = Locale(identifier: "en_US_POSIX")
            out.dateFormat = "MMM dd, yyyy"
            return out.string(from: date)
        }
        // Try without fractional seconds.
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) {
            let out = DateFormatter()
            out.locale = Locale(identifier: "en_US_POSIX")
            out.dateFormat = "MMM dd, yyyy"
            return out.string(from: date)
        }
        return nil
    }
}
