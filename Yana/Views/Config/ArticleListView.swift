import SwiftData
import SwiftUI

/// A second view of the reader's timeline: the same articles under the same shared `AppSettings`
/// filter, plus a predicate-backed full-text search. Tapping a row reports the article via
/// `onSelect` so the reader can jump to it; the row matching `currentArticleID` is highlighted
/// and scrolled into view on appear. Keeps swipe actions (star/reload) and swipe-to-delete.
struct ArticleListView: View {
    let currentArticleID: String?
    /// The open article's `serverID`, alongside `currentArticleID`. `identifier` is only a per-feed
    /// dedup key (two feeds can share a source URL), so every "is this the open row" check below
    /// prefers this globally-unique id when it's present -- see `TimelinePageIndex.index`.
    var currentArticleServerID: Int? = nil
    let onSelect: (ArticleSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchResults: [ArticleSummary]? = nil
    @State private var showFilter = false
    @State private var summaryToDelete: ArticleSummary?
    @State private var toast: ToastMessage?

    private var isUpdating: Bool { UpdateActivity.shared.isUpdating }

    /// Browsing reads the in-memory index (already in the timeline's canonical
    /// `(createdAt, serverID)` order — see `TimelineOrder`); a search swaps in predicate-fetched
    /// results. Both run through the shared tag/feed filter so the list stays a subset of the reader
    /// timeline, and since filtering only removes rows, browsing shows exactly the reader's order —
    /// including the row for the article currently open, which stays put when it is marked read.
    ///
    /// Cached, not computed (mirrors `MacSidebarView.displayed`, audit P7): `body` re-runs on every
    /// searchable keystroke and every store publish; the three filter passes only need to re-run
    /// when one of their real inputs changes.
    ///
    /// Seeded from the caller's own `store`/`settings` at `init` time (see the designated `init`
    /// below), not left as an empty default filled only by `.onAppear`: `ManagedList` seeds its
    /// hide-until-scrolled `revealed` state from whether `scrollToID` is non-nil at ITS construction
    /// time, and `scrollToID` here is derived from `results`. An empty starting value would make
    /// `currentItemID` `nil` on the very first `body` pass, permanently missing that one-shot reveal
    /// gate and silently breaking "open the list already parked on the current article."
    @State private var results: [ArticleSummary]

    init(currentArticleID: String?,
         currentArticleServerID: Int? = nil,
         onSelect: @escaping (ArticleSummary) -> Void,
         store: ArticleStore,
         settings: AppSettings) {
        self.currentArticleID = currentArticleID
        self.currentArticleServerID = currentArticleServerID
        self.onSelect = onSelect
        self._results = State(initialValue: Self.filteredResults(base: store.summaries, settings: settings))
    }

    /// The shared tag/feed/starred filter chain, factored out so both the designated `init` (which
    /// seeds `results` before `@Environment` is even resolved) and `recomputeResults()` (which reads
    /// it afterward) apply the exact same rules.
    private static func filteredResults(base: [ArticleSummary], settings: AppSettings) -> [ArticleSummary] {
        let byTag = TagFilter.apply(to: base,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        return StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
    }

    /// Recomputes the cached `results` from its real inputs. Called from the `onChange`/`onAppear`
    /// handlers attached to `body`, never from `body` itself.
    private func recomputeResults() {
        let base = searchResults ?? store.summaries
        results = Self.filteredResults(base: base, settings: settings)
    }

    private var isFilterActive: Bool { settings.isTimelineFilterActive }

    private func article(for summary: ArticleSummary) -> Article? {
        ArticleResolution.resolve(summary, in: modelContext)
    }

    /// Whether `summary` is the article currently open in the reader. Prefers `serverID` when known
    /// (see `currentArticleServerID`'s doc comment); falls back to `identifier` only when no
    /// `serverID` is available.
    private func isCurrent(_ summary: ArticleSummary) -> Bool {
        if let currentArticleServerID {
            return summary.serverID == currentArticleServerID
        }
        return currentArticleID != nil && summary.identifier == currentArticleID
    }

    var body: some View {
        let isPaired = AuthenticatedClient.current() != nil
        let currentItemID = results.first { isCurrent($0) }?.id
        return ManagedList(
            items: results,
            searchText: $searchText,
            emptyTitle: "No Articles",
            emptyIcon: "tray",
            emptyDescription: "No articles yet. Update all from the reader, or add feeds on your server.",
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
                // Dropped while unpaired/demo: there's no server to reload this article against.
                if isPaired {
                    Button {
                        guard let article = article(for: summary),
                              let client = AuthenticatedClient.current(),
                              let serverID = article.serverID
                        else { return }
                        UpdateActivity.shared.restart {
                            let result = await ReaderActions.forceUpdateArticle(
                                article, serverID: serverID, client: client, container: modelContext.container
                            )
                            switch result {
                            case .cancelled:
                                return
                            case .applied(let feedName):
                                toast = ToastMessage(text: RefreshOutcome.message(newCount: 0, feedName: feedName))
                            case .failed:
                                toast = ToastMessage(
                                    text: String(localized: "Could not reload this article. Please try again."),
                                    style: .error
                                )
                            }
                        }
                    } label: {
                        Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    .tint(.orange)
                }
            }
        ) { summary in
            Button { onSelect(summary) } label: { row(summary) }
                .buttonStyle(.plain)
                .listRowBackground(isCurrent(summary)
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
        .onAppear { recomputeResults() }
        .onChange(of: store.summaries) { _, _ in recomputeResults() }
        .onChange(of: searchResults) { _, _ in recomputeResults() }
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeResults() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeResults() }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeResults() }
        .onChange(of: settings.starredOnly) { _, _ in recomputeResults() }
        .navigationTitle("Articles")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
            ToolbarItem(placement: .topBarLeading) {
                if isUpdating {
                    Button { UpdateActivity.shared.cancel() } label: {
                        ZStack {
                            ProgressView()
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text("Stop updating"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilter = true } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(Text("Filter articles"))
                .accessibilityValue(isFilterActive ? Text("Filter active") : Text(""))
            }
        }
        .sheet(isPresented: $showFilter) { TagFilterView() }
        .toast($toast)
        .alert(
            String(localized: "Delete Article?"),
            isPresented: Binding(get: { summaryToDelete != nil }, set: { if !$0 { summaryToDelete = nil } })
        ) {
            if let summary = summaryToDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let article = article(for: summary) {
                        modelContext.delete(article)
                        try? modelContext.save()
                        // This is a local-only removal `/articles/sync`'s `removed` list will never
                        // report, so it can't trip `SyncEngine.performSync`'s prune gate on its own --
                        // flag it explicitly so the next sync's `pruneOrphanedImages` pass catches
                        // any image this was the last reference to.
                        settings.imagePruneNeeded = true
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
        searchResults = await ArticleSearch.searchSummaries(query: q, container: modelContext.container)
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
        let isCurrent = isCurrent(summary)
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
