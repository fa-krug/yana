import SwiftData
import SwiftUI

/// A second view of the reader's timeline: the same articles under the same shared `AppSettings`
/// filter, plus an in-memory search. Tapping a row reports the article via `onSelect` so the
/// reader can jump to it; the row matching `currentArticleID` is highlighted and scrolled into
/// view on appear. Keeps swipe actions (star/reload) and swipe-to-delete.
struct ArticleListView: View {
    let currentArticleID: String?
    let onSelect: (Article) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(ArticleListView.timelineDescriptor) private var allArticles: [Article]

    static var timelineDescriptor: FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            // Ascending import date: oldest first, so the list reads top = old, bottom = new
            // (matching the reader's left = old, right = new).
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return descriptor
    }
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var showFilter = false
    @State private var articleToDelete: Article?

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    /// Shared, app-lifetime flag so the spinner survives leaving and returning to this screen.
    private var isUpdating: Bool { UpdateActivity.shared.isUpdating }

    /// Same pipeline as `ReaderScreen.recomputeFilter` (TagFilter → FeedFilter over the shared
    /// `AppSettings` filter) plus the search layer, so results are a subset of the reader timeline.
    private var results: [Article] {
        let searched = ArticleSearch.filter(allArticles, query: debouncedSearch)
        let byTag = TagFilter.apply(to: searched,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        return FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    }

    private var isFilterActive: Bool { settings.isTimelineFilterActive }

    /// Persistent id (not the String identifier) of the currently-selected article, for scrolling.
    private var currentItemID: Article.ID? {
        results.first { $0.identifier == currentArticleID }?.id
    }

    var body: some View {
        ManagedList(
            items: results,
            searchText: $searchText,
            searchPrompt: "Search articles",
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "No articles yet. Add feeds, then pull to refresh.",
            onDelete: { offsets in
                guard let article = offsets.map({ results[$0] }).first else { return }
                articleToDelete = article
            },
            scrollToID: currentItemID,
            leadingActions: { article in
                Button {
                    guard let starredTag else { return }
                    article.setStarred(!article.isStarred, using: starredTag)
                    try? modelContext.save()
                    Haptics.impact(.light)
                } label: {
                    Label(article.isStarred ? "Unstar" : "Star",
                          systemImage: article.isStarred ? "star.slash" : "star")
                }
                .tint(.yellow)
                Button {
                    UpdateActivity.shared.restart {
                        await AggregationService(context: modelContext).forceReload(article: article)
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .tint(.orange)
            }
        ) { article in
            Button { onSelect(article) } label: { row(article) }
                .buttonStyle(.plain)
                .listRowBackground(article.identifier == currentArticleID
                                   ? Color.accentColor.opacity(0.15) : nil)
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
        .navigationTitle("Articles")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
            ToolbarItem(placement: .topBarLeading) {
                if isUpdating {
                    Button { UpdateActivity.shared.cancel() } label: { ProgressView() }
                        .accessibilityLabel(Text("Stop updating"))
                }
            }
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
        .sheet(isPresented: $showFilter) { TagFilterView() }
        .confirmationDialog(
            String(localized: "Delete Article?"),
            isPresented: Binding(get: { articleToDelete != nil }, set: { if !$0 { articleToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let article = articleToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    modelContext.delete(article)
                    try? modelContext.save()
                    Haptics.notify(.success)
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
        HStack(spacing: 12) {
            FeedLogoView(hash: article.feed?.logoHash)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let name = article.feed?.name, !name.isEmpty {
                        Text(name)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(article.date, style: .date)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
    }
}
