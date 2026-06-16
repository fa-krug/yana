import Foundation
import SwiftData

/// Decomposed, bindable editing state for a `Feed`. Holds a single `AggregatorOptions`
/// value (edited via the dynamic form); changing the type resets options to that type's
/// defaults. `apply(to:availableTags:)` writes the state back onto a `Feed`.
@MainActor
@Observable
final class FeedEditorModel {
    var name: String
    var type: AggregatorType
    var identifier: String
    var dailyLimit: Int
    var enabled: Bool
    var options: AggregatorOptions
    /// Tags chosen by name (resolved to `Tag` instances on apply).
    var selectedTagNames: Set<String>

    let isEditingExisting: Bool

    init(feed: Feed?) {
        if let feed {
            name = feed.name
            type = feed.type
            identifier = feed.identifier
            dailyLimit = feed.dailyLimit
            enabled = feed.enabled
            options = feed.options
            selectedTagNames = Set(feed.tags.map(\.name))
            isEditingExisting = true
        } else {
            name = ""
            type = .feedContent
            identifier = ""
            dailyLimit = 20
            enabled = true
            options = AggregatorType.feedContent.defaultOptions
            selectedTagNames = []
            isEditingExisting = false
        }
    }

    var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if type.identifierKind == .none { return true }
        return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func changeType(_ newType: AggregatorType) {
        type = newType
        options = newType.defaultOptions
        if let first = newType.identifierChoices.first,
           !newType.identifierChoices.contains(where: { $0.value == identifier }) {
            identifier = first.value
        }
    }

    func apply(to feed: Feed, availableTags: [Tag]) {
        feed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.type = type
        feed.identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        feed.dailyLimit = dailyLimit
        feed.enabled = enabled
        feed.options = options
        feed.tags = availableTags.filter { selectedTagNames.contains($0.name) }
        feed.updatedAt = .now
    }
}
