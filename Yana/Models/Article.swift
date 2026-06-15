import Foundation
import SwiftData

@Model
final class Article {
    var title: String = ""
    /// URL or external id; dedup key within a feed.
    var identifier: String = ""
    var url: String = ""
    var rawContent: String = ""
    var content: String = ""
    var date: Date = Date.now
    var author: String = ""
    var iconURL: String?
    var createdAt: Date = Date.now

    /// Snapshot of the feed's tags at import, plus the built-in Starred tag when starred.
    var tags: [Tag] = []

    var feed: Feed?

    init(
        title: String,
        identifier: String,
        url: String,
        rawContent: String = "",
        content: String = "",
        date: Date = .now,
        author: String = "",
        iconURL: String? = nil
    ) {
        self.title = title
        self.identifier = identifier
        self.url = url
        self.rawContent = rawContent
        self.content = content
        self.date = date
        self.author = author
        self.iconURL = iconURL
        self.createdAt = .now
    }

    /// Starred state is expressed purely as membership of the built-in tag.
    var isStarred: Bool { tags.contains { $0.isBuiltIn } }

    /// Add or remove the built-in Starred tag.
    func setStarred(_ starred: Bool, using starredTag: Tag) {
        if starred {
            if !tags.contains(where: { $0.id == starredTag.id }) { tags.append(starredTag) }
        } else {
            tags.removeAll { $0.isBuiltIn }
        }
    }
}
