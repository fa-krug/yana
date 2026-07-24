import SwiftData
import SwiftUI
import UIKit

/// Bridges the UIKit reader into SwiftUI: feeds the filtered timeline + selected index down to
/// `ReaderArticleViewController` and reports index changes back up. The chrome buttons call back
/// into SwiftUI for the Filter/Settings sheets and starring.
struct ReaderHostView: UIViewControllerRepresentable {
    let articles: [ArticleSummary]
    /// Resolves a summary to its full `Article`; passed straight to the pager.
    let resolveArticle: (ArticleSummary) -> Article?
    @Binding var currentIndex: Int
    /// Fired only when the *user* pages to a new article (swipe completes), never for the
    /// programmatic index updates that restore/reanchor perform. The host uses this to persist
    /// the reading position, so a transient reanchor fallback can never overwrite the saved anchor.
    var onUserNavigate: ((Int) -> Void)?
    let isRefreshing: Bool
    let isFilterActive: Bool
    var onRefresh: (() -> Void)?
    /// Fired from the empty-timeline page's shortcut button to start creating the first feed.
    var onCreateFeed: (() -> Void)?
    var onShowFilter: (() -> Void)?
    var onShowArticleList: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleStar: ((Article) -> Void)?
    var onForceUpdateArticle: ((Article) -> Void)?
    var onCopyLink: ((Article) -> Void)?
    var onSummarize: ((Article) -> Void)?
    let aiReady: Bool
    let isSummarizing: Bool
    /// Bumped by the host after a summary is written so the displayed page re-renders.
    let reloadToken: Int

    func makeUIViewController(context: Context) -> UINavigationController {
        StartupTrace.event("ReaderHost.makeUIViewController")
        let reader = ReaderArticleViewController()
        context.coordinator.reader = reader
        reader.resolveArticle = resolveArticle
        reader.onIndexChange = { i in currentIndex = i; onUserNavigate?(i) }
        reader.onShowFilter = onShowFilter
        reader.onShowArticleList = onShowArticleList
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.onForceUpdateArticle = onForceUpdateArticle
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
        reader.onCreateFeed = onCreateFeed
        reader.aiReady = aiReady
        reader.isSummarizing = isSummarizing
        context.coordinator.lastReloadToken = reloadToken
        reader.configure(articles: articles, index: currentIndex)
        reader.setRefreshing(isRefreshing)
        reader.setFilterActive(isFilterActive)

        let nav = UINavigationController(rootViewController: reader)
        nav.isToolbarHidden = false
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        guard let reader = context.coordinator.reader else { return }
        reader.resolveArticle = resolveArticle
        reader.onIndexChange = { i in currentIndex = i; onUserNavigate?(i) }
        reader.onShowFilter = onShowFilter
        reader.onShowArticleList = onShowArticleList
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.onForceUpdateArticle = onForceUpdateArticle
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
        reader.onCreateFeed = onCreateFeed
        reader.aiReady = aiReady
        reader.isSummarizing = isSummarizing
        // MUST run before the reloadToken re-render: clearing summaryPending here lets the
        // subsequent reloadCurrentPage render the real summary; the unchanged-HTML guard then
        // collapses the double render and the placeholder converges correctly.
        reader.setSummarizing(isSummarizing)
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            reader.reloadCurrentPage()
        }
        reader.update(articles: articles, index: currentIndex)
        reader.setRefreshing(isRefreshing)
        reader.setFilterActive(isFilterActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var reader: ReaderArticleViewController?
        var lastReloadToken = 0
    }
}

/// The home surface: owns the timeline `@Query`, tag filter, position memory, refresh, and the
/// Settings/Filter sheets. Replaces the former `ArticleReaderView`.
struct ReaderScreen: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(ArticleStore.self) private var store

    init(appState: AppState) {
        self.appState = appState
    }

    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var didRestoreAnchor = false
    @State private var toast: ToastMessage?
    @State private var isSummarizing = false
    @State private var reloadToken = 0
    @State private var showingCreateFeed = false
    /// Set by the Settings "Show Welcome Screen Again" row; consumed once the Settings sheet has
    /// fully dismissed so the welcome cover presents cleanly (no stacked-presentation race).
    @State private var restartOnboardingPending = false

    @State private var filteredArticles: [ArticleSummary] = []

    /// Re-filter only (used by tag/feed/untagged setting changes — position is preserved/clamped
    /// elsewhere).
    private func recomputeFilter() {
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        filteredArticles = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    }

    /// First load: filter + position on the saved anchor in one pass, so the reader is built
    /// already on the anchor. Subsequent deliveries refilter and re-resolve the displayed article.
    private func applyTimeline() {
        guard !didRestoreAnchor else {
            recomputeFilter()
            reanchorToCurrentArticle()
            return
        }
        let resolved = TimelineBootstrap.resolve(
            summaries: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged,
            disabledFeedNames: settings.disabledFeedNames,
            anchorIdentifier: settings.timelineAnchorIdentifier
        )
        filteredArticles = resolved.articles
        guard !resolved.articles.isEmpty else { return }   // wait for a non-empty delivery to anchor
        appState.currentIndex = resolved.anchorIndex
        didRestoreAnchor = true
    }

    /// Jump the reader to the synced timeline anchor article. Driven by `timelinePositionDidChange`
    /// (posted when a pull applies a remote anchor UID). Sets `currentIndex` directly — never via
    /// `saveAnchor` — so a remote jump can't loop back into a push.
    private func jumpToSyncedTimelinePosition() {
        guard didRestoreAnchor,
              let uid = settings.timelineAnchorIdentifier,
              let i = filteredArticles.firstIndex(where: { $0.identifier == uid }) else { return }
        appState.currentIndex = i
    }

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    private var aiReady: Bool { AIReadiness.isReady(provider: settings.activeAIProvider) }

    var body: some View {
        let articles = filteredArticles
        Group {
            switch TimelineLoadState.derive(hasComputedFilter: store.hasLoaded, count: articles.count) {
            case .loading:
                // No placeholder while the timeline resolves — just the plain background,
                // which avoids both the skeleton shape and a wrong "No Articles" flash.
                Color(.systemBackground)
                    .ignoresSafeArea()
            case .empty, .loaded:
                // Render the reader even with an empty timeline so its nav-bar chrome stays put;
                // the pager shows a zero-state page offering a direct "create feed" shortcut.
                ReaderHostView(
                    articles: articles,
                    resolveArticle: { ArticleResolution.resolve($0, in: modelContext) },
                    currentIndex: $appState.currentIndex,
                    onUserNavigate: { saveAnchor(at: $0) },
                    isRefreshing: UpdateActivity.shared.isUpdating || isSummarizing,
                    isFilterActive: settings.isTimelineFilterActive,
                    onRefresh: triggerRefresh,
                    onCreateFeed: { showingCreateFeed = true },
                    onShowFilter: { appState.showFilter = true },
                    onShowArticleList: { appState.showArticleList = true },
                    onShowSettings: { appState.showSettings = true },
                    onToggleStar: toggleStar,
                    onForceUpdateArticle: forceUpdateArticle,
                    onCopyLink: copyLink,
                    onSummarize: summarize,
                    aiReady: aiReady,
                    isSummarizing: isSummarizing,
                    reloadToken: reloadToken
                )
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $appState.showSettings, onDismiss: {
            if restartOnboardingPending {
                restartOnboardingPending = false
                appState.showWelcome = true
            }
        }) {
            NavigationStack {
                SettingsScreenView(onRestartOnboarding: { restartOnboardingPending = true })
            }
        }
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack {
                FeedEditorView(feed: nil) { newFeed in
                    // Fetch the just-added feed right away, unless it was created disabled.
                    guard newFeed.enabled else { return }
                    createFeed(newFeed)
                }
            }
        }
        .sheet(isPresented: $appState.showArticleList) {
            NavigationStack {
                ArticleListView(
                    currentArticleID: filteredArticles.indices.contains(appState.currentIndex)
                        ? filteredArticles[appState.currentIndex].identifier : nil,
                    onSelect: openArticle
                )
            }
        }
        .sheet(isPresented: $appState.showFilter, onDismiss: clampIndex) { TagFilterView() }
        .toast($toast)
        .onAppear {
            applyTimeline()
            if !settings.hasSeenFullscreenHint, UIDevice.current.userInterfaceIdiom == .phone {
                toast = ToastMessage(text: String(localized: "Tap the title bar to hide the toolbars."))
                settings.hasSeenFullscreenHint = true
            }
        }
        .onChange(of: store.summaries) { _, _ in
            applyTimeline()
        }
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeFilter() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeFilter() }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeFilter() }
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.timelinePositionDidChange)) { _ in
            jumpToSyncedTimelinePosition()
        }
    }

    private func toggleStar(_ article: Article) {
        guard let starredTag else { return }
        article.setStarred(!article.isStarred, using: starredTag)
        try? modelContext.save()
        Haptics.impact(.light)
        if let uid = ArticleUID.make(for: article) {
            Task { await ArticleSyncService.shared.push(uids: [uid]) }
        }
    }

    private func copyLink(_ article: Article) {
        UIPasteboard.general.string = article.url
    }

    /// Jump the reader to an article picked from the list. Recompute first so an in-list filter
    /// change is reflected, then resolve by identifier (not a stale index) and dismiss the sheet.
    private func openArticle(_ summary: ArticleSummary) {
        recomputeFilter()
        if let i = TimelinePageIndex.index(of: summary.identifier, in: filteredArticles) {
            appState.currentIndex = i
            settings.timelineAnchorIdentifier = summary.identifier
        }
        appState.showArticleList = false
    }

    private func summarize(_ article: Article) {
        guard !isSummarizing else { return }
        isSummarizing = true
        Task {
            let ok = await AggregationService(context: modelContext).summarize(article)
            isSummarizing = false
            if ok {
                reloadToken += 1
            } else {
                toast = ToastMessage(
                    text: String(localized: "Could not summarize this article. Please try again."),
                    style: .error
                )
            }
        }
    }

    // MARK: - Anchor (position memory)

    /// Persist the reading position. Called only from a completed user swipe (`onUserNavigate`),
    /// so it records exactly the article the user paged to and is never reached by the programmatic
    /// index moves of restore/reanchor/clamp — which previously could overwrite the anchor with a
    /// fallback position.
    private func saveAnchor(at index: Int) {
        let articles = filteredArticles
        guard articles.indices.contains(index) else { return }
        settings.timelineAnchorIdentifier = articles[index].identifier
        ConfigSyncService.shared.requestPush()
    }

    /// Keep the displayed article selected across timeline mutations (refresh / reload / retention
    /// cleanup) by re-resolving its saved anchor identifier to its new position, rather than holding
    /// a now-stale positional index. When the anchored article is *not* in the current slice (a
    /// partial/streamed query delivery, or a transient empty state mid-refresh) we leave the index
    /// untouched and wait for the next delivery — moving to a fallback here would jump the reader
    /// and, before, persist that wrong position as the new anchor.
    private func reanchorToCurrentArticle() {
        guard let i = TimelinePageIndex.index(of: settings.timelineAnchorIdentifier, in: filteredArticles) else {
            return
        }
        appState.currentIndex = i
    }

    private func clampIndex() {
        let clamped = min(appState.currentIndex, max(0, filteredArticles.count - 1))
        if clamped != appState.currentIndex {
            toast = ToastMessage(text: String(localized: "Showing the nearest article in this filter."))
        }
        appState.currentIndex = clamped
    }

    // MARK: - Refresh

    /// Force-update only the current article: re-fetch and re-process the single article in place,
    /// leaving the rest of the timeline untouched. Falls back to a forced reload of the owning
    /// feed when the source cannot re-fetch a lone item (see `AggregationService.forceReload`).
    private func forceUpdateArticle(_ article: Article) {
        let feedName = article.feed?.name
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let count = await service.forceReload(article: article)
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                toast = ToastMessage(text: failure, style: .error)
            } else {
                // Re-render the visible page: forceReload refreshed the article's content in
                // place, but the WKWebView only re-renders when reloadToken changes (same as
                // summarize). Without this bump, Reload silently updates the DB while the page
                // keeps showing the stale content.
                reloadToken += 1
                toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feedName))
                Haptics.impact(.light)
            }
        }
    }

    /// Fetch a freshly created feed right away so its articles replace the empty state
    /// (mirrors the Feeds screen's create path).
    private func createFeed(_ feed: Feed) {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).update(feed: feed)
            guard !Task.isCancelled else { return }
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feed.name))
        }
    }

    private func triggerRefresh() {
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let count = await service.updateAll()
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                toast = ToastMessage(text: failure, style: .error)
            } else {
                toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: nil))
                Haptics.impact(.light)
            }
        }
    }
}

/// Presents a `UIActivityViewController` from SwiftUI (used by the search detail + link sheets).
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
