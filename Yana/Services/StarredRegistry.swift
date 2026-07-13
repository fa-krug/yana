import Foundation
import SwiftData

/// Lightweight, Codable identity for a starred article — used to sync the "starred" set
/// across devices without syncing article bodies.
struct StarredMark: Codable, Hashable, Sendable {
    let feedIdentifier: String
    let aggregatorType: String
    let articleIdentifier: String
}

/// Device-local store for the set of `StarredMark`s. The sync layer calls `update(to:)` after
/// a pull and reads `all` before a push; `AggregationService` reads `identifiers(forFeedIdentifier:aggregatorType:)`
/// at import time so newly fetched articles that are already starred in the registry come in starred.
@MainActor
final class StarredRegistry {
    static let shared = StarredRegistry()

    private let defaults: UserDefaults
    private static let defaultsKey = "starred.marks"

    private var marks: Set<StarredMark>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Set<StarredMark>.self, from: data) {
            self.marks = decoded
        } else {
            self.marks = []
        }
    }

    var all: Set<StarredMark> { marks }

    func contains(_ mark: StarredMark) -> Bool {
        marks.contains(mark)
    }

    /// Returns the article identifiers whose mark matches the given feed identity.
    func identifiers(forFeedIdentifier feedIdentifier: String, aggregatorType: String) -> Set<String> {
        Set(marks.compactMap { mark in
            mark.feedIdentifier == feedIdentifier && mark.aggregatorType == aggregatorType
                ? mark.articleIdentifier
                : nil
        })
    }

    /// Replace all marks, persist to `UserDefaults`, and return whether the set changed.
    /// Called by the sync layer after a pull.
    @discardableResult
    func update(to newMarks: Set<StarredMark>) -> Bool {
        guard newMarks != marks else { return false }
        marks = newMarks
        persist()
        return true
    }

    /// Add a single mark and persist.
    func add(_ mark: StarredMark) {
        marks.insert(mark)
        persist()
    }

    /// Remove a single mark and persist.
    func remove(_ mark: StarredMark) {
        marks.remove(mark)
        persist()
    }

    /// Collect all starred articles from the context and map each to a `StarredMark`.
    /// Articles whose `feed` is nil are skipped.
    static func collect(from context: ModelContext) -> Set<StarredMark> {
        let descriptor = FetchDescriptor<Article>()
        let articles = (try? context.fetch(descriptor)) ?? []
        var result = Set<StarredMark>()
        for article in articles where article.isStarred {
            guard let feed = article.feed else { continue }
            result.insert(StarredMark(
                feedIdentifier: feed.identifier,
                aggregatorType: feed.aggregatorType,
                articleIdentifier: article.identifier
            ))
        }
        return result
    }

    /// Reconcile local articles' Starred tag to match the registry.
    /// Articles starred locally but absent from the registry become unstarred;
    /// articles whose mark is in the registry become starred.
    func applyToLocalArticles(in context: ModelContext) {
        Tag.ensureBuiltIns(in: context)
        let tagDescriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        guard let starredTag = (try? context.fetch(tagDescriptor))?.first else { return }

        let descriptor = FetchDescriptor<Article>()
        let articles = (try? context.fetch(descriptor)) ?? []
        for article in articles {
            guard let feed = article.feed else { continue }
            let mark = StarredMark(
                feedIdentifier: feed.identifier,
                aggregatorType: feed.aggregatorType,
                articleIdentifier: article.identifier
            )
            let shouldStar = contains(mark)
            if shouldStar != article.isStarred {
                article.setStarred(shouldStar, using: starredTag)
            }
        }
        try? context.save()
    }

    // MARK: - Private

    private func persist() {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
