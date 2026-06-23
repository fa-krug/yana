import Foundation

/// Persists the lightweight article index to disk so a warm cold-start can paint the timeline
/// without any SwiftData fetch. Lives in Caches (a derived artifact; if purged, `ArticleStore`
/// falls back to an anchor-centered DB window). An `actor` so all file IO runs off the main actor.
actor SummaryIndexCache {
    static let shared = SummaryIndexCache()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.fileURL = dir.appendingPathComponent("summary-index.plist")
        }
    }

    /// The cached index, or `nil` when the file is absent or fails to decode. `nil` is a clean
    /// signal to fall back to the DB — never a crash.
    func load() -> [ArticleSummary]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode([ArticleSummary].self, from: data)
    }

    /// Replace the cached index. Failures are swallowed: the cache is best-effort and the DB
    /// remains the source of truth.
    func save(_ summaries: [ArticleSummary]) {
        guard let data = try? PropertyListEncoder().encode(summaries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
