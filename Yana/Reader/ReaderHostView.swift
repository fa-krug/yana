import SwiftData
import SwiftUI
import UIKit

/// Bridges the UIKit reader into SwiftUI: feeds the filtered timeline + selected index down to
/// `ReaderArticleViewController` and reports index changes back up. The chrome buttons call back
/// into SwiftUI for the Filter/Settings sheets and starring.
struct ReaderHostView: UIViewControllerRepresentable {
    let articles: [Article]
    @Binding var currentIndex: Int
    let isRefreshing: Bool
    let isFilterActive: Bool
    var onRefresh: (() -> Void)?
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
        let reader = ReaderArticleViewController()
        context.coordinator.reader = reader
        reader.onIndexChange = { currentIndex = $0 }
        reader.onShowFilter = onShowFilter
        reader.onShowArticleList = onShowArticleList
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.onForceUpdateArticle = onForceUpdateArticle
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
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
        reader.onIndexChange = { currentIndex = $0 }
        reader.onShowFilter = onShowFilter
        reader.onShowArticleList = onShowArticleList
        reader.onShowSettings = onShowSettings
        reader.onToggleStar = onToggleStar
        reader.onRefresh = onRefresh
        reader.onForceUpdateArticle = onForceUpdateArticle
        reader.onCopyLink = onCopyLink
        reader.onSummarize = onSummarize
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

    @Query(ReaderScreen.timelineDescriptor) private var allArticles: [Article]

    static var timelineDescriptor: FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Batch-load the relationships every page render touches, avoiding N+1 faulting.
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return descriptor
    }
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var didRestoreAnchor = false
    @State private var statusMessage: String?
    @State private var isSummarizing = false
    @State private var reloadToken = 0
    @State private var summarizeFailed = false

    @State private var filteredArticles: [Article] = []
    @State private var hasComputedFilter = false

    private func recomputeFilter() {
        let byTag = TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        filteredArticles = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        hasComputedFilter = true
    }

    private var starredTag: Tag? { builtInTags.first { $0.name == Tag.starredName } }

    private var aiReady: Bool { AIReadiness.isReady(provider: settings.activeAIProvider) }

    var body: some View {
        let articles = filteredArticles
        Group {
            switch TimelineLoadState.derive(hasComputedFilter: hasComputedFilter, count: articles.count) {
            case .loading:
                SkeletonTimelineView()
            case .empty:
                ContentUnavailableView {
                    Label("No Articles", systemImage: "tray")
                        .accessibilityIdentifier("emptyArticlesTitle")
                } description: {
                    Text("Add feeds in Settings, then pull down to refresh.")
                } actions: {
                    Button(String(localized: "Add Your First Feed")) { appState.showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded:
                ReaderHostView(
                    articles: articles,
                    currentIndex: $appState.currentIndex,
                    isRefreshing: UpdateActivity.shared.isUpdating || isSummarizing,
                    isFilterActive: settings.isTimelineFilterActive,
                    onRefresh: triggerRefresh,
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
        .sheet(isPresented: $appState.showSettings) { NavigationStack { SettingsScreenView() } }
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
        .alert("Summarize Failed", isPresented: $summarizeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Could not summarize this article. Please try again.")
        }
        .alert("Update Failed", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("Retry") { triggerRefresh() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: statusMessage) {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.statusMessage = nil
                    }
            }
        }
        .animation(.snappy, value: statusMessage)
        .onAppear {
            recomputeFilter()
            restoreAnchor()
            if !settings.hasSeenFullscreenHint, UIDevice.current.userInterfaceIdiom == .phone {
                statusMessage = String(localized: "Tap the title bar to hide the toolbars.")
                settings.hasSeenFullscreenHint = true
            }
        }
        .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
        .onChange(of: allArticles) { _, _ in
            recomputeFilter()
            if didRestoreAnchor { reanchorToCurrentArticle() } else { restoreAnchor() }
        }
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeFilter() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeFilter() }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeFilter() }
    }

    private func toggleStar(_ article: Article) {
        guard let starredTag else { return }
        article.setStarred(!article.isStarred, using: starredTag)
        try? modelContext.save()
        Haptics.impact(.light)
    }

    private func copyLink(_ article: Article) {
        UIPasteboard.general.string = article.url
    }

    /// Jump the reader to an article picked from the list. Recompute first so an in-list filter
    /// change is reflected, then resolve by identifier (not a stale index) and dismiss the sheet.
    private func openArticle(_ article: Article) {
        recomputeFilter()
        if let i = TimelinePageIndex.index(of: article.identifier, in: filteredArticles) {
            appState.currentIndex = i
            settings.timelineAnchorIdentifier = article.identifier
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
                summarizeFailed = true
            }
        }
    }

    // MARK: - Anchor (position memory)

    private func restoreAnchor() {
        let articles = filteredArticles
        guard !articles.isEmpty, !didRestoreAnchor else { return }
        appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: articles)
        didRestoreAnchor = true
    }

    private func saveAnchor() {
        let articles = filteredArticles
        guard !articles.isEmpty else { return }
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else { return }
        settings.timelineAnchorIdentifier = articles[appState.currentIndex].identifier
    }

    /// Keep the displayed article selected across timeline mutations (refresh / reload / retention
    /// cleanup) by re-resolving its saved anchor identifier to its new position, rather than holding
    /// a now-stale positional index. Falls back to the top only if the article is gone.
    private func reanchorToCurrentArticle() {
        appState.currentIndex = TimelineAnchor.index(
            for: settings.timelineAnchorIdentifier, in: filteredArticles
        )
    }

    private func clampIndex() {
        let clamped = min(appState.currentIndex, max(0, filteredArticles.count - 1))
        if clamped != appState.currentIndex {
            statusMessage = String(localized: "Showing the nearest article in this filter.")
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
                appState.errorMessage = failure
            } else {
                statusMessage = RefreshOutcome.message(newCount: count, feedName: feedName)
                Haptics.impact(.light)
            }
        }
    }

    private func triggerRefresh() {
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let count = await service.updateAll()
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                appState.errorMessage = failure
            } else {
                statusMessage = RefreshOutcome.message(newCount: count, feedName: nil)
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
