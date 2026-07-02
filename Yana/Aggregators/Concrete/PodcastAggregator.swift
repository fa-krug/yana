import Foundation

/// Podcast aggregator: an RSS pipeline that builds artwork / HTML5 audio player / duration /
/// download / show-notes markup. Episodes without an audio enclosure are skipped.
/// (Native AVPlayer is out of scope — HTML5 `<audio>` only.)
class PodcastAggregator: RSSPipelineAggregator, @unchecked Sendable {
    private var podcastOptions: PodcastOptions {
        if case .podcast(let o) = config.options { return o }
        return PodcastOptions()
    }

    /// Episodes with no audio enclosure are dropped at make-time via `AggregatorError.articleSkip`
    /// (the base pipeline catches it and omits the article).
    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        guard let (mediaURL, mediaType) = pickAudioEnclosure(entry) else {
            throw AggregatorError.articleSkip(statusCode: 0)
        }
        let opts = podcastOptions
        var parts: [String] = []

        // Artwork (downloaded + cached).
        if let imageURL = artworkURL(entry), let remote = URL(string: imageURL),
           let hash = await store.store(remoteURL: remote, isHeader: true) {
            parts.append("""
            <div data-sanitized-class="podcast-artwork" style="margin-bottom: 1em;">\
            <img src="\(ReaderWeb.imageScheme)://\(hash)" alt="\(String(localized: "Episode artwork"))" \
            style="max-width: \(opts.artworkSize)px; height: auto; border-radius: 8px;"></div>
            """)
        }

        // Player (open div if included).
        if opts.includePlayer {
            parts.append("""
            <div data-sanitized-class="podcast-player" style="margin-bottom: 1em;">\
            <audio controls preload="metadata" style="width: 100%;">\
            <source src="\(mediaURL)" type="\(mediaType)">\
            Your browser does not support the audio element.</audio>
            """)
        }

        // Duration + download meta.
        var meta: [String] = []
        if let seconds = parseDuration(entry.itunesDuration) {
            meta.append("<span data-sanitized-class=\"podcast-duration\">\(String(localized: "Duration:")) \(formatDuration(seconds))</span>")
        }
        if opts.includeDownloadLink {
            meta.append("<a href=\"\(mediaURL)\" data-sanitized-class=\"podcast-download\" download>\(String(localized: "Download Episode"))</a>")
        }
        if (opts.includePlayer || opts.includeDownloadLink) && !meta.isEmpty {
            parts.append("<div style=\"margin-top: 0.5em; font-size: 0.9em; color: #666;\">\(meta.joined(separator: " | "))</div>")
        }
        if opts.includePlayer { parts.append("</div>") }

        // Show notes.
        let notes = entry.summary ?? entry.entryDescription ?? entry.content ?? ""
        if !notes.isEmpty {
            parts.append("<div data-sanitized-class=\"podcast-description\"><h4>\(String(localized: "Show Notes"))</h4>\(notes)</div>")
        }

        var article = article
        let combined = parts.joined(separator: "\n")
        // Reuse the base content pipeline (sanitize/clean/wrap with footer); artwork already localized.
        article.content = try await processContent(combined, article: article, headerHTML: nil)
        return article
    }

    // MARK: - Enclosure + media helpers

    private func pickAudioEnclosure(_ entry: FeedEntry) -> (url: String, type: String)? {
        let audioExts = [".mp3", ".m4a", ".ogg", ".opus", ".wav"]
        for enc in entry.enclosures {
            let type = enc.type ?? ""
            let isAudio = type.hasPrefix("audio/") || audioExts.contains { enc.url.lowercased().hasSuffix($0) }
            if isAudio { return (enc.url, type.isEmpty ? "audio/mpeg" : type) }
        }
        return nil
    }

    private func artworkURL(_ entry: FeedEntry) -> String? {
        if let img = entry.itunesImage, !img.isEmpty { return img }
        return entry.mediaThumbnails.first
    }

    func parseDuration(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.range(of: #"^\d+$"#, options: .regularExpression) != nil { return Int(s) }
        let parts = s.split(separator: ":").map { Int($0) }
        if parts.count == 3, let h = parts[0], let m = parts[1], let sec = parts[2] { return h * 3600 + m * 60 + sec }
        if parts.count == 2, let m = parts[0], let sec = parts[1] { return m * 60 + sec }
        return nil
    }

    func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
