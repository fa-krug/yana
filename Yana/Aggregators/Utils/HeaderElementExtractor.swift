import Foundation

/// The lead media for an article header: ready-to-insert HTML, plus the original image URL
/// (if any) so the body can de-dup it.
struct HeaderElement: Sendable { var html: String; var dedupURL: String? }

/// Strategy chain mirroring services/header_element: YouTube thumbnail/embed → generic image.
/// (Reddit-specific strategies live in the Reddit aggregator, Phase 4e.)
enum HeaderElementExtractor {
    static func extract(articleURL: String, title: String, store: ImageStore, credentials: AggregatorCredentials, pageHTML: String? = nil) async -> HeaderElement? {
        // 0. Domain override: use the configured image URL instead of any extraction strategy.
        if let overrideURL = DomainImageOverrides.overrideImageURL(for: articleURL),
           let url = URL(string: overrideURL),
           let hash = await store.store(remoteURL: url, isHeader: true) {
            let html = ContentFormatter.headerImageHTML(src: "\(ReaderWeb.imageScheme)://\(hash)", alt: title)
            return HeaderElement(html: html, dedupURL: overrideURL)
        }
        // 1. YouTube → embed header (no image download needed).
        if let id = EmbedRewriter.extractYouTubeID(from: articleURL) {
            let embed = EmbedRewriter.youTubeEmbedHTML(videoID: id)
            let html = "<header style=\"margin-bottom: 1.5em;\">\(embed)</header>"
            return HeaderElement(html: html, dedupURL: nil)
        }
        // 2. Generic lead image: only when the URL looks like an image.
        if looksLikeImage(articleURL), let url = URL(string: articleURL),
           let hash = await store.store(remoteURL: url, isHeader: true) {
            let html = ContentFormatter.headerImageHTML(src: "\(ReaderWeb.imageScheme)://\(hash)", alt: title)
            return HeaderElement(html: html, dedupURL: articleURL)
        }
        // 3. og:image / twitter:image from already-fetched page HTML (MetaTagImageStrategy).
        if let html = pageHTML, let resolved = metaImageURL(pageHTML: html, articleURL: articleURL),
           let url = URL(string: resolved),
           let hash = await store.store(remoteURL: url, isHeader: true) {
            let imgHTML = ContentFormatter.headerImageHTML(src: "\(ReaderWeb.imageScheme)://\(hash)", alt: title)
            return HeaderElement(html: imgHTML, dedupURL: resolved)
        }
        return nil
    }

    /// The og:image (preferred) or twitter:image URL declared in `pageHTML`, resolved against
    /// `articleURL`. Pure — no network — so callers that already hold the page HTML (e.g. the
    /// Reddit link-post scrape) can reuse the meta-tag strategy. Returns nil when neither tag is
    /// present or has content.
    static func metaImageURL(pageHTML: String, articleURL: String) -> String? {
        guard let doc = try? HTMLUtils.parse(pageHTML) else { return nil }
        let rawOG = try? doc.select("meta[property=og:image]").first()?.attr("content")
        let rawTW = try? doc.select("meta[name=twitter:image]").first()?.attr("content")
        guard let raw = (rawOG.flatMap { $0.isEmpty ? nil : $0 }) ?? (rawTW.flatMap { $0.isEmpty ? nil : $0 })
        else { return nil }
        return URL(string: raw, relativeTo: URL(string: articleURL))?.absoluteString ?? raw
    }

    static func looksLikeImage(_ url: String) -> Bool {
        let path = URLComponents(string: url)?.path ?? url
        let ext = (path as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext)
    }
}
