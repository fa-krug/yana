import Foundation

/// Which conditional items the reader's overflow menu should show for the current article.
/// Force update is unconditional and not represented here.
struct ReaderMenuConfig: Equatable {
    var showCopyLink: Bool
    var showSummarize: Bool
}

enum ReaderMenuBuilder {
    static func config(hasURL: Bool, aiReady: Bool) -> ReaderMenuConfig {
        ReaderMenuConfig(showCopyLink: hasURL, showSummarize: aiReady)
    }
}
