import SwiftData
import SwiftUI

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

/// A second view of the reader's timeline: the same articles under the same shared `AppSettings`
/// filter, plus a predicate-backed full-text search. Tapping a row reports the article via
/// `onSelect` so the reader can jump to it; the row matching `currentArticleID` is highlighted
/// and scrolled into view on appear. Keeps swipe actions (star/reload) and swipe-to-delete.
struct ArticleListView: View {
    let currentArticleID: String?
    let onSelect: (ArticleSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    @State private var settings = AppSettings()
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResults: [ArticleSummary]? = nil
    @State private var showFilter = false
    @State private var summaryToDelete: ArticleSummary?

    private var isUpdating: Bool { UpdateActivity.shared.isUpdating }

    /// Browsing reads the in-memory index; a search swaps in predicate-fetched results. Both run
    /// through the shared tag/feed filter so the list stays a subset of the reader timeline.
    private var results: [ArticleSummary] {
        let base = searchResults ?? store.summaries
        let byTag = TagFilter.apply(to: base,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        return StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
    }

    private var isFilterActive: Bool { settings.isTimelineFilterActive }

    private func article(for summary: ArticleSummary) -> Article? {
        ArticleResolution.resolve(summary, in: modelContext)
    }

    var body: some View {
        let results = results
        let currentItemID = results.first { $0.identifier == currentArticleID }?.id
        return ManagedList(
            items: results,
            searchText: $searchText,
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "No articles yet. Add feeds, then pull to refresh.",
            onDelete: { offsets in
                guard let summary = offsets.map({ results[$0] }).first else { return }
                summaryToDelete = summary
            },
            scrollToID: currentItemID,
            leadingActions: { summary in
                Button {
                    guard let article = article(for: summary) else { return }
                    ArticleWrites.toggleStar(article, modelContext: modelContext)
                    Haptics.impact(.light)
                } label: {
                    Label(summary.isStarred ? "Unstar" : "Star",
                          systemImage: summary.isStarred ? "star.slash" : "star")
                }
                .tint(.yellow)
                Button {
                    guard let article = article(for: summary),
                          let client = AuthenticatedClient.current(),
                          let serverID = article.serverID
                    else { return }
                    UpdateActivity.shared.restart {
                        do {
                            let jobId = try await ArticleActions(client: client).reload(articleServerID: serverID)
                            guard !Task.isCancelled else { return }
                            // See `UpdateAndSync.pollForReloadedContent`'s doc comment: this
                            // deliberately re-fetches this one article's content directly rather
                            // than going through `SyncEngine`'s generic `hasContent`-gated
                            // backfill, which a premature fetch during the poll window could
                            // permanently lock out of any later retry. `article` is registered on
                            // this view's `modelContext`, the same context the reader (presented
                            // from) reads from -- pass it as `visibleArticle` so a reload of the
                            // currently-open (or previously-viewed) article updates that live
                            // object too, not just the store.
                            await UpdateAndSync.pollForReloadedContent(
                                jobId: jobId, articleServerID: serverID, container: modelContext.container, client: client,
                                visibleArticle: article
                            )
                        } catch {
                            // Matches the pre-server behavior of swallowing a failed reload
                            // silently -- this swipe action has no toast/error surface.
                        }
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .tint(.orange)
            }
        ) { summary in
            Button { onSelect(summary) } label: { row(summary) }
                .buttonStyle(.plain)
                .listRowBackground(summary.identifier == currentArticleID
                                   ? Color.accentColor.opacity(0.15) : nil)
        }
        // `ManagedList` doesn't own `.searchable()` itself (see its doc comment); this view isn't
        // `.id()`-wrapped, so there's nothing special here beyond attaching it directly.
        .searchable(text: $searchText, placement: ManagedListSearch.placement, prompt: "Search articles")
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
        .task(id: debouncedSearch) { await runSearch() }
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
                Button { showFilter = true } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilter) { TagFilterView() }
        .alert(
            String(localized: "Delete Article?"),
            isPresented: Binding(get: { summaryToDelete != nil }, set: { if !$0 { summaryToDelete = nil } })
        ) {
            if let summary = summaryToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let article = article(for: summary) {
                        modelContext.delete(article)
                        try? modelContext.save()
                        Haptics.notify(.success)
                    }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let summary = summaryToDelete {
                Text(String(localized: "Delete \u{201C}\(summary.title)\u{201D}? This cannot be undone."))
            }
        }
    }

    /// Run the full-text predicate fetch while a query is active; clear back to the index otherwise.
    private func runSearch() async {
        let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = nil; return }
        var descriptor = FetchDescriptor<Article>(
            predicate: ArticleListSearch.predicate(for: q),
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt]
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        let tagNamesByID = ArticleSummary.tagNameLookup(in: modelContext)
        searchResults = matches.map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
    }

    /// The Mac's roomier rows read better with a touch more space between title and subline;
    /// iOS keeps the compact 4pt to preserve its denser timeline-adjacent look.
    private var rowLineSpacing: CGFloat {
        #if targetEnvironment(macCatalyst)
        6
        #else
        4
        #endif
    }

    private func row(_ summary: ArticleSummary) -> some View {
        let isCurrent = summary.identifier == currentArticleID
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Color.accentColor : Color.clear)
                .frame(width: 3)
            FeedLogoView(hash: summary.feedLogoHash)
            VStack(alignment: .leading, spacing: rowLineSpacing) {
                HStack(spacing: 6) {
                    if !summary.isRead {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(Text("Unread"))
                    }
                    Text(summary.title).font(.headline).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if !summary.feedName.isEmpty {
                        Text(summary.feedName)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(summary.date, style: .date)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
            if isCurrent {
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(Text("Current article"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
