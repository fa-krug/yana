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

    /// Cold open materializes only the newest `limit` articles (nil = unbounded). The window grows
    /// as the user scrolls to the end, and goes unbounded while a search is active so search stays
    /// complete. Owned by the presenter (ReaderScreen) so it survives this view's re-inits.
    @Binding var limit: Int?
    @Query private var allArticles: [Article]

    init(currentArticleID: String?, limit: Binding<Int?>, onSelect: @escaping (Article) -> Void) {
        self.currentArticleID = currentArticleID
        self._limit = limit
        self.onSelect = onSelect
        // @Query can't take a dynamic fetchLimit via its macro, so build it here in init.
        _allArticles = Query(Self.timelineDescriptor(limit: limit.wrappedValue))
    }

    static func timelineDescriptor(limit: Int?) -> FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            // Window the *newest* page: sort by descending import date so `fetchLimit` keeps the
            // most-recent `limit` articles (an ascending sort would keep the oldest, leaving the
            // reader's current article outside the window). `results` reverses the fetch to display
            // top = old, bottom = new, matching the reader's left = old, right = new.
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
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
        // The query returns newest-first to window the newest page; reverse to chronological
        // (oldest → new) so the list reads top = old, bottom = new like the reader timeline.
        let chronological = Array(allArticles.reversed())
        let searched = ArticleSearch.filter(chronological, query: debouncedSearch)
        let byTag = TagFilter.apply(to: searched,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        return FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    }

    private var isFilterActive: Bool { settings.isTimelineFilterActive }

    /// More articles may exist beyond the loaded window: the raw fetch filled the limit. (When the
    /// limit is nil the window is unbounded, so the database is fully loaded.)
    private var canLoadMore: Bool {
        guard let limit else { return false }
        return allArticles.count >= limit
    }

    var body: some View {
        // Compute the filtered/searched list once per render: it is read for the rows, the
        // scroll-to target, and delete resolution, and re-runs on every keystroke otherwise.
        let results = results
        let currentItemID = results.first { $0.identifier == currentArticleID }?.id
        return ManagedList(
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
                .onAppear { loadMoreIfNeeded(appearing: article, in: results) }
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
        .onChange(of: debouncedSearch) { _, query in
            // A search must scan the whole library, so drop the window while one is active;
            // restore it when the search clears so browsing stays fast.
            limit = query.isEmpty ? TimelineWindow.pageSize : nil
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

    /// Grow the window when the oldest loaded row (top of the list) appears — browse only, since
    /// search is already unbounded. The window holds the newest page, so growth loads *older*
    /// articles at the top. Stops once the database is exhausted (`canLoadMore` is false).
    private func loadMoreIfNeeded(appearing article: Article, in results: [Article]) {
        guard debouncedSearch.isEmpty, canLoadMore, let limit,
              article.id == results.first?.id else { return }
        self.limit = TimelineWindow.nextLimit(limit)
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
