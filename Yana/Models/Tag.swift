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

    /// Inserts the built-in Starred tag if missing. Returns `true` when it inserted (so the
    /// caller can save only when something changed), `false` when one already existed.
    @discardableResult
    static func ensureBuiltIns(in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return false }
        context.insert(Tag(name: starredName, colorHex: "#F5C518", isBuiltIn: true, sortOrder: -1))
        return true
    }
}
