import Foundation
import SwiftData

@Model
final class Tag {
    var name: String = ""
    var colorHex: String?
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(inverse: \Feed.tags)
    var feeds: [Feed]?

    @Relationship(inverse: \Article.tags)
    var articles: [Article]?

    init(name: String, colorHex: String? = nil, sortOrder: Int = 0) {
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = .now
    }
}
