import SwiftData
import SwiftUI

/// Searchable + filterable list of all articles (newest first), reachable from the config hub.
/// Tapping a row opens a read-only detail; swipe to delete. Search matches
/// title/content/author/feed name in memory; the tag filter is transient (local state, never
/// `AppSettings`) so it never affects the home timeline.
struct ArticleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var searchText = ""
    @State private var disabledTagNames: Set<String> = []
    @State private var includeUntagged = true
    @State private var showFilter = false
    @State private var articleToDelete: Article?

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    private var results: [Article] {
        let searched = ArticleSearch.filter(allArticles, query: searchText)
        return TagFilter.apply(to: searched, disabledTagNames: disabledTagNames, includeUntagged: includeUntagged)
    }

    private var isFilterActive: Bool {
        !disabledTagNames.isEmpty || !includeUntagged
    }

    var body: some View {
        ManagedList(
            items: results,
            searchText: $searchText,
            searchPrompt: "Search articles",
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "Add feeds and refresh to see articles here.",
            onDelete: { offsets in
                // Resolve immediately so stale indices can't delete the wrong article
                guard let article = offsets.map({ results[$0] }).first else { return }
                articleToDelete = article
            },
            leadingActions: { article in
                Button {
                    guard let starredTag else { return }
                    article.setStarred(!article.isStarred, using: starredTag)
                    try? modelContext.save()
                } label: {
                    Label(article.isStarred ? "Unstar" : "Star",
                          systemImage: article.isStarred ? "star.slash" : "star")
                }
                .tint(.yellow)
                Button {
                    Task { await AggregationService(context: modelContext).update(article: article) }
                } label: {
                    Label("Update", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        ) { article in
            NavigationLink {
                ArticleDetailView(article: article)
            } label: {
                row(article)
            }
        }
        .navigationTitle("Articles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilter = true
                } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilter) {
            ArticleTagFilterView(disabledTagNames: $disabledTagNames, includeUntagged: $includeUntagged)
        }
        .confirmationDialog(
            String(localized: "Delete Article?"),
            isPresented: Binding(get: { articleToDelete != nil }, set: { if !$0 { articleToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let article = articleToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    modelContext.delete(article)
                    try? modelContext.save()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let article = articleToDelete {
                Text(String(localized: "Delete \u{201C}\(article.title)\u{201D}? This cannot be undone."))
            }
        }
    }

    private func row(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if let name = article.feed?.name, !name.isEmpty {
                    Text(name).foregroundStyle(Color.accentColor)
                    Text("·")
                }
                Text(article.date, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
