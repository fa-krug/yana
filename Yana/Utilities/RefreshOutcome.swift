import Foundation

/// Builds the user-facing toast after a feed refresh. Shared by the Feeds screen and the
/// home reader so both report new-article counts identically.
enum RefreshOutcome {
    static func message(newCount: Int, feedName: String?) -> String {
        if newCount == 0 {
            if let name = feedName {
                return String(localized: "Reloaded \u{201C}\(name)\u{201D}.")
            }
            return String(localized: "No new articles.")
        }
        let articleWord = newCount == 1 ? String(localized: "article") : String(localized: "articles")
        if let name = feedName {
            return String(localized: "Added \(newCount) new \(articleWord) from \u{201C}\(name)\u{201D}.")
        }
        return String(localized: "Added \(newCount) new \(articleWord).")
    }
}
