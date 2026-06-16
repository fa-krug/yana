import Foundation

/// Case/diacritic-insensitive substring search across an article's title, content (HTML),
/// author, and source feed name. In-memory filtering is fine given retention keeps the
/// article set bounded (~one month).
@MainActor
enum ArticleSearch {
    static func matches(_ article: Article, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let haystacks = [article.title, article.content, article.author, article.feed?.name ?? ""]
        return haystacks.contains { $0.localizedStandardContains(q) }
    }

    static func filter(_ articles: [Article], query: String) -> [Article] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return articles }
        return articles.filter { matches($0, query: q) }
    }
}
