import Foundation

/// Pure policy for the reader's windowed timeline fetch. The timeline `@Query` is bounded by a
/// `fetchLimit` so cold launch materializes only the newest page of articles instead of the whole
/// library; the window grows on demand. Two forces drive growth, both expressed by `shouldExtend`:
///
/// 1. **Swipe-driven** — as the reader's current index approaches the end of the loaded (filtered)
///    list, we load the next page so the pager always has neighbors ahead.
/// 2. **Filter-driven** — an active tag/feed filter can hide most of the newest page, so after
///    filtering we keep extending until enough articles are visible (or the database is exhausted).
///
/// `loadedRawCount == currentLimit` means the fetch returned a full page, so older rows *may* exist;
/// once it returns fewer than the limit the database is exhausted and we stop (the loop terminates).
enum TimelineWindow {
    /// Articles materialized on the first fetch and added on each extension.
    static let pageSize = 100
    /// How many filtered articles to keep loaded ahead of the current index.
    static let lookahead = 25

    /// Whether the window must grow to keep `lookahead` filtered articles available beyond `index`.
    /// Returns false once the database is exhausted, guaranteeing the extend loop terminates.
    static func shouldExtend(
        loadedRawCount: Int,
        currentLimit: Int,
        filteredCount: Int,
        index: Int,
        lookahead: Int = lookahead
    ) -> Bool {
        let databaseExhausted = loadedRawCount < currentLimit
        guard !databaseExhausted else { return false }
        return filteredCount < index + lookahead
    }

    /// The next fetch limit after an extension.
    static func nextLimit(_ current: Int, pageSize: Int = pageSize) -> Int {
        current + pageSize
    }
}
