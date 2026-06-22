import Foundation

/// Pure policy for the reader's windowed timeline fetch. The timeline `@Query` fetches by
/// *descending* import date bounded by a `fetchLimit`, so cold launch materializes only the newest
/// page of articles instead of the whole library; the views reverse the result to display
/// oldest → new. The window grows on demand toward *older* articles. Two forces drive growth, both
/// expressed by `shouldExtend`:
///
/// 1. **Swipe-driven** — as the reader's current index approaches the oldest loaded article
///    (index 0, the front of the displayed list), we load the next page so the pager always has
///    older neighbors behind it.
/// 2. **Filter-driven** — an active tag/feed filter can hide most of the loaded page, leaving too
///    few articles older than the index; we keep extending until enough are available (or the
///    database is exhausted).
///
/// `loadedRawCount == currentLimit` means the fetch returned a full page, so older rows *may* exist;
/// once it returns fewer than the limit the database is exhausted and we stop (the loop terminates).
enum TimelineWindow {
    /// Articles materialized on the first fetch and added on each extension.
    static let pageSize = 100
    /// How many filtered articles to keep loaded older than (behind) the current index.
    static let lookahead = 25

    /// Whether the window must grow to keep `lookahead` filtered articles loaded *older* than
    /// `index`. `index` is the current article's position in the oldest → new display, so it is
    /// exactly the count of older filtered articles already loaded. Returns false once the database
    /// is exhausted, guaranteeing the extend loop terminates.
    static func shouldExtend(
        loadedRawCount: Int,
        currentLimit: Int,
        index: Int,
        lookahead: Int = lookahead
    ) -> Bool {
        let databaseExhausted = loadedRawCount < currentLimit
        guard !databaseExhausted else { return false }
        return index < lookahead
    }

    /// The next fetch limit after an extension.
    static func nextLimit(_ current: Int, pageSize: Int = pageSize) -> Int {
        current + pageSize
    }
}
