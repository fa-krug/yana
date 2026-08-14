import Foundation
import SwiftData

/// Case/diacritic-insensitive search across an article's title, body text (`plainText`, the blocks
/// flattened to visible text), author, and source feed name. Runs entirely as a SwiftData
/// `#Predicate` fetch — there is deliberately no in-memory matcher any more, so the iOS list and the
/// Mac sidebar cannot drift apart in what they consider a match.
@MainActor
enum ArticleSearch {
    /// Runs the predicate-backed `FetchDescriptor` search (title/body/author/feed name, sorted by
    /// date ascending, only the fields the timeline row needs) and maps the matches through
    /// `ArticleSummary`'s tag-name lookup. Shared by `ArticleListView` (iOS) and `MacRootView`'s
    /// sidebar (Mac) so both searches stay predicate-for-predicate identical.
    static func searchSummaries(query: String, in modelContext: ModelContext) -> [ArticleSummary] {
        var descriptor = FetchDescriptor<Article>(
            predicate: ArticleListSearch.predicate(for: query),
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        descriptor.propertiesToFetch = ArticleSummary.fetchedProperties
        descriptor.relationshipKeyPathsForPrefetching = [\.feed]
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        let tagNamesByID = ArticleSummary.tagNameLookup(in: modelContext)
        return matches.map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
    }
}

/// Full-text search over title / body text / author / feed name, case- & diacritic-insensitive.
/// Matches against `plainText` (the body flattened to visible text), evaluated over rows that
/// project only scalar fields.
enum ArticleListSearch {
    // NOTE: The #Predicate macro cannot type-check the full four-field expression in one block
    // (type-check timeout). Split into two complementary predicates: one for the article's own
    // string fields, one for the feed name. Both are combined at fetch time.
    static func titleContentAuthorPredicate(for query: String) -> Predicate<Article> {
        let q = query
        return #Predicate<Article> { article in
            article.title.localizedStandardContains(q)
                || article.plainText.localizedStandardContains(q)
                || article.author.localizedStandardContains(q)
        }
    }

    static func feedNamePredicate(for query: String) -> Predicate<Article> {
        let q = query
        return #Predicate<Article> { article in
            article.feed?.name.localizedStandardContains(q) == true
        }
    }

    /// Builds a compound `Predicate<Article>` that matches title, content, author, or feed name.
    static func predicate(for query: String) -> Predicate<Article> {
        let tca = titleContentAuthorPredicate(for: query)
        let fn  = feedNamePredicate(for: query)
        return #Predicate<Article> { article in
            tca.evaluate(article) || fn.evaluate(article)
        }
    }
}
