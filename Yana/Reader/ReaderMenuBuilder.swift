import Foundation

/// Which conditional items the reader's overflow menu should show for the current article.
struct ReaderMenuConfig: Equatable {
    var showReload: Bool
    var showCopyLink: Bool
    var showSummarize: Bool
    var showOpenOnServer: Bool
}

enum ReaderMenuBuilder {
    /// `hasServerArticle` gates both Reload and Open on Server: both need a paired server AND
    /// this article's `serverID` (the server-side identity `ArticleActions.reload` and the
    /// `/articles/:id` web route both key off).
    static func config(hasURL: Bool, aiReady: Bool, hasServerArticle: Bool) -> ReaderMenuConfig {
        ReaderMenuConfig(
            showReload: hasServerArticle,
            showCopyLink: hasURL,
            showSummarize: aiReady,
            showOpenOnServer: hasServerArticle
        )
    }
}
