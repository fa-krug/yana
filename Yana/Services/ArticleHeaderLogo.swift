import Foundation

/// Builds the feed-logo `<img>` for the article header. Empty string when the feed has no
/// cached logo. The image is served via the `yana-img://` scheme (no remote URL).
enum ArticleHeaderLogo {
    static func imgTag(logoHash: String?) -> String {
        guard let logoHash, !logoHash.isEmpty else { return "" }
        return "<img class=\"feed-logo\" src=\"\(ReaderWeb.imageScheme)://\(logoHash)\" alt=\"\">"
    }
}
