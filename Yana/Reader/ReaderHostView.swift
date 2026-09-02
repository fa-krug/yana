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
    var onArticleDisplayed: ((Article) -> Void)?
    let isRefreshing: Bool
    let isFilterActive: Bool
    var onRefresh: (() -> Void)?
    /// Fired from the empty-timeline page's shortcut button to start creating the first feed.
    var onCreateFeed: (() -> Void)?
    /// Fired from the empty-timeline page's shortcut button (unpaired variant) to start pairing.
    var onPairServer: (() -> Void)?
    var onShowFilter: (() -> Void)?
    var onShowArticleList: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleStar: ((Article) -> Void)?
    var onForceUpdateArticle: ((Article) -> Void)?
    var onCopyLink: ((Article) -> Void)?
    var onSummarize: ((Article) -> Void)?
    var onOpenOnServer: ((Article) -> Void)?
    let aiReady: Bool
    let hasServer: Bool
    let isSummarizing: Bool
    /// Bumped by the host after a summary is written so the displayed page re-renders.
    let reloadToken: Int

    func makeUIViewController(context: Context) -> UINavigationController {
        StartupTrace.event("ReaderHost.makeUIViewController")
        let reader = ReaderArticleViewController()
        context.coordinator.reader = reader
        reader.resolveArticle = resolveArticle
        reader.onIndexChange = { i in currentIndex = i; onUserNavigate?(i) }
        reader.onArticleDisplayed = onArticleDisplayed
        reader.onShowFilter = onShowFilter
        reader.onShowArticleList = onShowArticleList
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.onForceUpdateArticle = onForceUpdateArticle
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
        reader.onOpenOnServer = onOpenOnServer
        reader.onCreateFeed = onCreateFeed
        reader.onPairServer = onPairServer
        reader.aiReady = aiReady
        reader.hasServer = hasServer
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
        reader.onArticleDisplayed = onArticleDisplayed
        reader.onShowFilter = onShowFilter
        reader.onShowArticleList = onShowArticleList
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.onForceUpdateArticle = onForceUpdateArticle
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
        reader.onOpenOnServer = onOpenOnServer
        reader.onCreateFeed = onCreateFeed
        reader.onPairServer = onPairServer
        reader.aiReady = aiReady
        reader.hasServer = hasServer
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
    @Environment(AppSettings.self) private var settings

    init(appState: AppState) {
        self.appState = appState
    }

    @State private var didRestoreAnchor = false
    @State private var toast: ToastMessage?
    @State private var isSummarizing = false
    @State private var reloadToken = 0
    @State private var showingCreateFeed = false
    /// Server-side article id to view in `ManagementWebView`, set by the reader's "Open on Server"
    /// menu action; `nil` means the sheet is dismissed.
    @State private var openOnServerArticleID: Int?
    /// Set by the Settings "Show Welcome Screen Again" row; consumed once the Settings sheet has
    /// fully dismissed so the welcome cover presents cleanly (no stacked-presentation race).
    @State private var restartOnboardingPending = false
    /// Same pattern as `restartOnboardingPending`, for the Settings "Server Update Notice" row.
    @State private var showServerNoticePending = false

    @State private var filteredArticles: [ArticleSummary] = []

    /// The timeline-anchor read/write logic (see `ReaderAnchorController`), recreated on each access
    /// against this view's own `settings` — it holds no state of its own beyond that reference, so
    /// recreating it is free. Kept a computed property (not `@State`) because a struct's stored
    /// property initializers can't reference `self.settings`.
    private var anchorController: ReaderAnchorController { ReaderAnchorController(settings: settings) }

    /// Re-filter `store.summaries`. Filtering never reorders (see `TimelineOrder`), so the pager's
    /// order is stable no matter what the user marks read while navigating.
    /// Shared with `TimelineModel` (Mac) via `ReaderActions.recomputeFilter`.
    private func recomputeFilter() {
        filteredArticles = ReaderActions.recomputeFilter(summaries: store.summaries, settings: settings)
    }

    /// First load: filter + position on the saved anchor in one pass, so the reader is built
    /// already on the anchor. Subsequent deliveries refilter and re-resolve the displayed article.
    private func applyTimeline() {
        guard !didRestoreAnchor else {
            recomputeFilter()
            if !applyPendingRemotePosition() {
                reanchorToCurrentArticle()
            }
            return
        }
        let resolved = TimelineBootstrap.resolve(
            summaries: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged,
            disabledFeedNames: settings.disabledFeedNames,
            starredOnly: settings.starredOnly,
            readFilter: settings.readFilter,
            anchorIdentifier: settings.timelineAnchorIdentifier,
            anchorServerID: settings.timelineAnchorServerID
        )
        filteredArticles = resolved.articles
        guard !resolved.articles.isEmpty else { return }   // wait for a non-empty delivery to anchor
        appState.currentIndex = anchorController.jumpToSyncedTimelinePosition(in: resolved.articles) ?? resolved.anchorIndex

        didRestoreAnchor = true
    }

    /// Retries the pending remote position (see `AppSettings.pendingRemoteReadingPosition`) against
    /// `filteredArticles`, jumping to it if it now resolves. Called from `applyTimeline`'s
    /// post-first-load branch (so a position that hadn't synced down yet keeps retrying as later
    /// sync pages land) and from the `pendingRemoteReadingPosition` change handler below (so a
    /// live-pushed position that's already synced applies immediately instead of waiting for the
    /// next relaunch). Returns whether it applied, so callers can skip their own reanchor fallback.
    @discardableResult
    private func applyPendingRemotePosition() -> Bool {
        guard let i = anchorController.jumpToSyncedTimelinePosition(in: filteredArticles) else { return false }
        appState.currentIndex = i
        return true
    }



    private var hasServer: Bool { AuthenticatedClient.current() != nil }

    /// See `ReaderActions.aiReady`, shared with `TimelineModel` (Mac).
    private var aiReady: Bool { ReaderActions.aiReady(mode: settings.aiMode) }

    private var showDemoBanner: Bool {
        settings.hasSkippedServerPairing && !settings.hasDismissedDemoBanner && !hasServer
    }

    /// Dropped while unpaired/demo: there's nothing on a server to pull fresh content from.
    /// Precomputed (rather than inlined as a ternary in the view-builder call below) because the
    /// call's already-large parameter list pushes the type-checker over its time budget otherwise.
    private var onRefreshHandler: (() -> Void)? {
        guard hasServer else { return nil }
        return { self.triggerRefresh() }
    }

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
                    onArticleDisplayed: { markRead($0) },
                    isRefreshing: UpdateActivity.shared.isUpdating || isSummarizing,
                    isFilterActive: settings.isTimelineFilterActive,
                    onRefresh: onRefreshHandler,
                    onCreateFeed: { showingCreateFeed = true },
                    onPairServer: {
                        appState.welcomeInitialStep = .server
                        appState.showWelcome = true
                    },
                    onShowFilter: { appState.showFilter = true },
                    onShowArticleList: { appState.showArticleList = true },
                    onShowSettings: { appState.showSettings = true },
                    onToggleStar: toggleStar,
                    onForceUpdateArticle: forceUpdateArticle,
                    onCopyLink: copyLink,
                    onSummarize: summarize,
                    onOpenOnServer: { openOnServerArticleID = $0.serverID },
                    aiReady: aiReady,
                    hasServer: hasServer,
                    isSummarizing: isSummarizing,
                    reloadToken: reloadToken
                )
                .ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .top) {
            if showDemoBanner {
                DemoModeBanner(
                    onPairNow: {
                        appState.welcomeInitialStep = .server
                        appState.showWelcome = true
                    },
                    onDismiss: { settings.hasDismissedDemoBanner = true }
                )
            }
        }
        .sheet(isPresented: $appState.showSettings, onDismiss: {
            if restartOnboardingPending {
                restartOnboardingPending = false
                appState.welcomeInitialStep = .welcome
                appState.showWelcome = true
            }
            if showServerNoticePending {
                showServerNoticePending = false
                appState.showServerMigrationNotice = true
            }
        }) {
            NavigationStack {
                SettingsScreenView(
                    onRestartOnboarding: { restartOnboardingPending = true },
                    onShowServerNotice: { showServerNoticePending = true }
                )
            }
        }
        .sheet(isPresented: $showingCreateFeed) {
            NavigationStack {
                ManagementWebView(
                    serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!,
                    path: "/feeds/new",
                    title: nil,
                    showsBackButton: true
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { openOnServerArticleID != nil },
            set: { if !$0 { openOnServerArticleID = nil } }
        )) {
            if let id = openOnServerArticleID {
                NavigationStack {
                    ManagementWebView(
                        serverBaseURL: URL(string: settings.serverBaseURL) ?? URL(string: "https://")!,
                        path: "/articles/\(id)",
                        title: nil,
                        showsBackButton: true
                    )
                }
            }
        }
        .sheet(isPresented: $appState.showArticleList) {
            NavigationStack {
                ArticleListView(
                    currentArticleID: filteredArticles.indices.contains(appState.currentIndex)
                        ? filteredArticles[appState.currentIndex].identifier : nil,
                    currentArticleServerID: filteredArticles.indices.contains(appState.currentIndex)
                        ? filteredArticles[appState.currentIndex].serverID : nil,
                    onSelect: openArticle,
                    store: store,
                    settings: settings
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
        .onChange(of: settings.pendingRemoteReadingPosition) { _, _ in
            if didRestoreAnchor { applyPendingRemotePosition() }
        }
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeFilter() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeFilter() }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeFilter() }
        .onChange(of: settings.starredOnly) { _, _ in recomputeFilter() }
        // Re-filtering removes rows around the page the reader is parked on, so its index moves
        // even though the article itself survives (`ReadFilter` exempts the anchor). Re-resolve
        // the index from the anchor rather than leaving a stale one pointing at another article;
        // the clamp is the fallback for an anchor that doesn't resolve at all.
        .onChange(of: settings.readFilter) { _, _ in
            recomputeFilter()
            reanchorToCurrentArticle()
            clampIndex()
        }
        // Observes `lastOutcome` whenever the article list sheet is NOT frontmost.
        // `ArticleListView` observes it itself while its sheet is up (see that view), so that a
        // reload triggered from its swipe action still gets a toast -- this reader's own toast
        // would otherwise render behind the sheet, invisible, and auto-expire before the user
        // dismisses it. The two observers are mutually exclusive by construction (this one skips
        // exactly when the other is mounted), so an outcome is never shown twice.
        .onChange(of: OperationMonitor.shared.lastOutcome) { _, outcome in
            guard let outcome, !appState.showArticleList else { return }
            toast = ReaderActions.outcomeToast(outcome)
            if ReaderActions.outcomeRefreshesVisiblePage(outcome) {
                // Re-render the visible page: the reload refreshed the article's content, but the
                // reader only re-renders when reloadToken changes (same as summarize).
                reloadToken += 1
            }
            switch outcome {
            case .reloaded, .updated:
                Haptics.impact(.light)
            case .failed, .unconfirmed:
                break
            }
        }

    }

    /// Toggles locally right away (optimistic) via `ArticleWrites`; queued for retry rather than
    /// rolled back on failure. Silently local-only when not paired.
    private func toggleStar(_ article: Article) {
        ArticleWrites.toggleStar(article, modelContext: modelContext)
        Haptics.impact(.light)
    }

    private func markRead(_ article: Article) {
        ArticleWrites.markRead(article, modelContext: modelContext)
    }

    private func copyLink(_ article: Article) {
        UIPasteboard.general.string = article.url
    }

    /// Jump the reader to an article picked from the list. Recompute first so an in-list filter
    /// change is reflected, then resolve by identifier (not a stale index) and dismiss the sheet.
    private func openArticle(_ summary: ArticleSummary) {
        recomputeFilter()
        if let i = TimelinePageIndex.index(of: summary.identifier, serverID: summary.serverID, in: filteredArticles) {
            appState.currentIndex = i
            anchorController.recordOpenedArticle(summary)
            if let article = ArticleResolution.resolve(summary, in: modelContext) {
                markRead(article)
            }
        }
        appState.showArticleList = false
    }

    /// Server-interaction sequencing shared with `TimelineModel` (Mac) via `ReaderActions.summarize`;
    /// this keeps the provider-resolution guard and the resulting UI state (isSummarizing, toast,
    /// reloadToken) local, since those are exactly where the two platforms legitimately differ.
    private func summarize(_ article: Article) {
        guard !isSummarizing else { return }
        let provider: AISummaryProvider
        if settings.aiMode == .appleIntelligence {
            provider = AppleIntelligenceSummaryProvider()
        } else if let client = AuthenticatedClient.current() {
            provider = ServerAISummaryProvider(client: client)
        } else {
            toast = ToastMessage(text: String(localized: "Not connected to a server."), style: .error)
            return
        }
        isSummarizing = true
        Task {
            let result = await ReaderActions.summarize(article, using: provider, modelContext: modelContext)
            isSummarizing = false
            switch result {
            case .saved:
                reloadToken += 1
            case .failed(let failure):
                toast = ToastMessage(text: ReaderActions.summarizeFailureMessage(failure), style: .error)
            }
        }
    }

    // MARK: - Anchor (position memory)

    /// Persist the reading position. Called only from a completed user swipe (`onUserNavigate`),
    /// so it records exactly the article the user paged to and is never reached by the programmatic
    /// index moves of restore/reanchor/clamp — which previously could overwrite the anchor with a
    /// fallback position. Delegates to `ReaderAnchorController`, which pushes the new anchor
    /// (coalesced) since this is the user-driven write path; `applyTimeline`'s first-load call to
    /// `ReaderAnchorController.jumpToSyncedTimelinePosition` is the remote-apply path and must
    /// never push, or two open devices would trade anchor writes forever — see
    /// `ReaderAnchorControllerTests` for the assertion.
    private func saveAnchor(at index: Int) {
        anchorController.saveAnchor(at: index, in: filteredArticles)
    }

    /// Keep the displayed article selected across timeline mutations (refresh / reload / retention
    /// cleanup) by delegating to `ReaderAnchorController.reanchorIndex`, which re-resolves the saved
    /// anchor (preferring the synced UID — see its doc comment for why that also self-heals a
    /// pending remote anchor) to its new position, rather than holding a now-stale positional index.
    /// When the anchor is *not* in the current slice (a partial/streamed query delivery, a transient
    /// empty state mid-refresh, or an article that hasn't synced yet) we leave the index untouched
    /// and wait for the next delivery — moving to a fallback here would jump the reader and persist
    /// that wrong position as the new anchor.
    private func reanchorToCurrentArticle() {
        guard let i = anchorController.reanchorIndex(in: filteredArticles) else { return }
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

    /// Triggers the server's per-article reload. The trigger only reports its own failure -- the
    /// POST's ack is a job id, not new content, so `OperationMonitor` (started inside
    /// `ReaderActions.startReload`) is what actually watches the job to completion and publishes
    /// the outcome the `.onChange(of: OperationMonitor.shared.lastOutcome)` handler below shows.
    private func forceUpdateArticle(_ article: Article) {
        guard let client = AuthenticatedClient.current(), let serverID = article.serverID else { return }
        Task {
            let started = await ReaderActions.startReload(
                article, serverID: serverID, client: client,
                container: modelContext.container, settings: settings
            )
            if !started {
                toast = ToastMessage(
                    text: String(localized: "Could not reload this article. Please try again."),
                    style: .error
                )
            }
        }
    }

    /// "Update" only triggers the server's aggregation run (`ArticleActions.updateAll()`); the run
    /// itself happens server-side and asynchronously, so `OperationMonitor` is what follows the run
    /// to completion and reports what it actually pulled in.
    private func triggerRefresh() {
        guard let client = AuthenticatedClient.current() else {
            toast = ToastMessage(text: String(localized: "Not connected to a server."), style: .error)
            return
        }
        Task {
            let started = await ReaderActions.startUpdateAll(
                client: client, container: modelContext.container, settings: settings
            )
            if !started {
                toast = ToastMessage(
                    text: String(localized: "Could not check for updates. Please try again."),
                    style: .error
                )
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
