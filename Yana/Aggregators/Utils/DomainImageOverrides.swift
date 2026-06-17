/// URL-prefix → image URL mapping that short-circuits normal image extraction.
///
/// When an article URL matches one of the registered prefixes, the configured
/// image URL is used instead of running the normal image extraction strategies.
/// Prefix matching uses `hasPrefix`; when several prefixes match, the longest
/// one wins (more specific paths can override broader domain entries).
enum DomainImageOverrides {
    /// Mapping of URL prefixes to the image URL that should be used as the
    /// article's header/icon image.
    static let overrides: [String: String] = [
        "https://en-americas-support.nintendo.com/": (
            "https://upload.wikimedia.org/wikipedia/commons/0/0d/Nintendo.svg"
        ),
    ]

    /// Returns an override image URL for the given article URL, if any.
    ///
    /// - Parameter url: The article URL to look up.
    /// - Returns: The override image URL when `url` starts with one of the
    ///   registered prefixes, otherwise `nil`. When several prefixes match,
    ///   the longest prefix wins.
    static func overrideImageURL(for url: String) -> String? {
        guard !url.isEmpty else { return nil }
        var longestMatch: String? = nil
        var longestLength = 0
        for (prefix, imageURL) in overrides {
            if url.hasPrefix(prefix) && prefix.count > longestLength {
                longestMatch = imageURL
                longestLength = prefix.count
            }
        }
        return longestMatch
    }
}
