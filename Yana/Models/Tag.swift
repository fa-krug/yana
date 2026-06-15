import Foundation
import SwiftData

@Model
final class Tag {
    var name: String = ""
    var colorHex: String?
    /// True only for the seeded, locked "Starred" tag.
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(inverse: \Feed.tags)
    var feeds: [Feed] = []

    @Relationship(inverse: \Article.tags)
    var articles: [Article] = []

    init(name: String, colorHex: String? = nil, isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    /// The canonical name of the built-in Starred tag.
    static let starredName = "Starred"

    /// Insert the built-in Starred tag if it isn't already present. Idempotent.
    static func ensureBuiltIns(in context: ModelContext) {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }
        context.insert(Tag(name: starredName, colorHex: "#F5C518", isBuiltIn: true, sortOrder: -1))
    }
}
