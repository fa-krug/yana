import SwiftData
import SwiftUI

/// Searchable list of all articles (newest first), reachable from the config hub. Tapping a
/// row opens a read-only detail; search matches title/content/author/feed name in memory.
struct ArticleListView: View {
    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @State private var searchText = ""

    private var results: [Article] {
        ArticleSearch.filter(allArticles, query: searchText)
    }

    var body: some View {
        List(results) { article in
            NavigationLink {
                ArticleDetailView(article: article)
            } label: {
                row(article)
            }
        }
        .navigationTitle("Articles")
        .searchable(text: $searchText, prompt: Text("Search articles"))
        .overlay {
            if results.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Articles", systemImage: "tray",
                                           description: Text("Add feeds and refresh to see articles here."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private func row(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if let name = article.feed?.name, !name.isEmpty {
                    Text(name).foregroundStyle(Color.accentColor)
                }
                Text("· \(article.date, style: .date)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
