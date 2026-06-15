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
    var read: Bool = false
    var starred: Bool = false
    var author: String = ""
    var iconURL: String?
    var createdAt: Date = Date.now

    var feed: Feed?

    init(
        title: String,
        identifier: String,
        url: String,
        rawContent: String = "",
        content: String = "",
        date: Date = .now,
        read: Bool = false,
        starred: Bool = false,
        author: String = "",
        iconURL: String? = nil
    ) {
        self.title = title
        self.identifier = identifier
        self.url = url
        self.rawContent = rawContent
        self.content = content
        self.date = date
        self.read = read
        self.starred = starred
        self.author = author
        self.iconURL = iconURL
        self.createdAt = .now
    }
}
