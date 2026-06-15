import Foundation
import SwiftData

@Model
final class FeedGroup {
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Feed.group)
    var feeds: [Feed] = []

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
    }
}
