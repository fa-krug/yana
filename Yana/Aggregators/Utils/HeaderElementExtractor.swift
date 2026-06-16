import Foundation

/// The lead media for an article header: ready-to-insert HTML, plus the original image URL
/// (if any) so the body can de-dup it.
struct HeaderElement: Sendable { var html: String; var dedupURL: String? }

/// Strategy chain mirroring services/header_element: YouTube thumbnail/embed → generic image.
/// (Reddit-specific strategies live in the Reddit aggregator, Phase 4e.)
enum HeaderElementExtractor {
    static func extract(articleURL: String, title: String, store: ImageStore, credentials: AggregatorCredentials) async -> HeaderElement? {
        // 1. YouTube → embed header (no image download needed).
        if let id = EmbedRewriter.extractYouTubeID(from: articleURL) {
            let embed = EmbedRewriter.youTubeEmbedHTML(videoID: id)
            let html = "<header style=\"margin-bottom: 1.5em;\">\(embed)</header>"
            return HeaderElement(html: html, dedupURL: nil)
        }
        // 2. Generic lead image: only when the URL looks like an image.
        guard looksLikeImage(articleURL), let url = URL(string: articleURL),
              let hash = await store.store(remoteURL: url, isHeader: true) else { return nil }
        let html = ContentFormatter.headerImageHTML(src: "\(ReaderWeb.imageScheme)://\(hash)", alt: title)
        return HeaderElement(html: html, dedupURL: articleURL)
    }

    private static func looksLikeImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { lower.contains($0) }
    }
}
