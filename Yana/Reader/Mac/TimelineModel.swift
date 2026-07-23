import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared timeline engine for the Mac window: filtering, selection/anchor memory, and the article
/// actions (refresh, star, summarize, force-update, copy link, create feed). Mirrors the logic
/// `ReaderScreen` runs on iOS, so the two surfaces behave identically; it is factored out here so
/// `MacRootView` and its toolbar/menu commands can drive one source of truth instead of duplicating
/// handlers.
///
/// Dependencies (`modelContext` + `ArticleStore`) come from the SwiftUI environment, which isn't
/// available at `init`, so callers `configure(...)` once from `.onAppear` before use.
@MainActor
@Observable
final class TimelineModel {
    /// The filtered timeline the sidebar lists and the reader pages through.
    private(set) var filteredArticles: [ArticleSummary] = []
    /// Index of the selected article within `filteredArticles`.
    var currentIndex = 0
    /// Bumped after a summary/force-reload writes new content so the detail page re-renders.
    private(set) var reloadToken = 0
    var isSummarizing = false
    var toast: ToastMessage?

    private let settings = AppSettings()
    private var didRestoreAnchor = false

    private var modelContext: ModelContext?
    private var store: ArticleStore?

    var isConfigured: Bool { modelContext != nil }

    func configure(modelContext: ModelContext, store: ArticleStore) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        self.store = store
    }

    // MARK: - Selection

    /// The selected article's stable identifier, bound to the sidebar `List(selection:)`. Setting it
    /// re-resolves the position by identifier (never a stale index) and persists it as the anchor.
    var selection: String? {
        get {
            filteredArticles.indices.contains(currentIndex)
                ? filteredArticles[currentIndex].identifier : nil
        }
        set {
            guard let id = newValue,
                  let i = TimelinePageIndex.index(of: id, in: filteredArticles) else { return }
            currentIndex = i
            settings.timelineAnchorIdentifier = id
        }
    }

    var selectedSummary: ArticleSummary? {
        filteredArticles.indices.contains(currentIndex) ? filteredArticles[currentIndex] : nil
    }

    /// Resolve the selected summary to its live `Article` (with body blocks) on demand.
    func selectedArticle() -> Article? {
        guard let modelContext, let summary = selectedSummary else { return nil }
        return ArticleResolution.resolve(summary, in: modelContext)
    }

    func resolve(_ summary: ArticleSummary) -> Article? {
        guard let modelContext else { return nil }
        return ArticleResolution.resolve(summary, in: modelContext)
    }

    /// Move the selection by `offset` (±1) and persist the new anchor. Powers the
    /// Next/Previous Article menu commands and their keyboard shortcuts.
    func moveSelection(by offset: Int) {
        guard !filteredArticles.isEmpty else { return }
        let next = min(max(currentIndex + offset, 0), filteredArticles.count - 1)
        guard next != currentIndex else { return }
        currentIndex = next
        settings.timelineAnchorIdentifier = filteredArticles[next].identifier
    }

    var aiReady: Bool { AIReadiness.isReady(provider: settings.activeAIProvider) }

    // MARK: - Filtering / anchor (mirrors ReaderScreen)

    func recomputeFilter() {
        guard let store else { return }
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        filteredArticles = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    }

    /// First load: filter + park on the saved anchor in one pass. Subsequent deliveries refilter and
    /// re-resolve the displayed article by identifier so mutations never jump the selection.
    func applyTimeline() {
        guard let store else { return }
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
        guard !resolved.articles.isEmpty else { return }
        currentIndex = resolved.anchorIndex
        didRestoreAnchor = true
    }

    private func reanchorToCurrentArticle() {
        guard let i = TimelinePageIndex.index(of: settings.timelineAnchorIdentifier, in: filteredArticles) else {
            return
        }
        currentIndex = i
    }

    /// Keep selection valid after the filter narrows the timeline.
    func clampIndex() {
        currentIndex = min(currentIndex, max(0, filteredArticles.count - 1))
    }

    // MARK: - Actions

    private var starredTag: Tag? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        return (try? modelContext.fetch(descriptor))?.first { $0.name == Tag.starredName }
    }

    func toggleStar(_ article: Article) {
        guard let modelContext, let starredTag else { return }
        article.setStarred(!article.isStarred, using: starredTag)
        try? modelContext.save()
        ConfigSyncService.shared.requestPush()
    }

    func copyLink(_ article: Article) {
        #if canImport(UIKit)
        UIPasteboard.general.string = article.url
        #endif
    }

    /// Open the article's original web page in the default browser. On the Mac the desktop
    /// expectation is the system browser, so this opens the URL directly rather than an in-app sheet.
    func openWebsite(_ article: Article) {
        #if canImport(UIKit)
        guard let url = URL(string: article.url) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    func summarize(_ article: Article) {
        guard let modelContext, !isSummarizing else { return }
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

    func forceUpdateArticle(_ article: Article) {
        guard let modelContext else { return }
        let feedName = article.feed?.name
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let count = await service.forceReload(article: article)
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                self.toast = ToastMessage(text: failure, style: .error)
            } else {
                self.reloadToken += 1
                self.toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feedName))
            }
        }
    }

    func triggerRefresh() {
        guard let modelContext else { return }
        UpdateActivity.shared.restart {
            let service = AggregationService(context: modelContext)
            let count = await service.updateAll()
            guard !Task.isCancelled else { return }
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                self.toast = ToastMessage(text: failure, style: .error)
            } else {
                self.toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: nil))
            }
        }
    }

    /// Fetch a freshly created feed right away so its articles replace the empty state.
    func createFeed(_ feed: Feed) {
        guard let modelContext, feed.enabled else { return }
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).update(feed: feed)
            guard !Task.isCancelled else { return }
            self.toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feed.name))
        }
    }
}
