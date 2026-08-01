import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A one-shot request to scroll the Mac sidebar to a specific row. `TimelineModel` bumps this only
/// from programmatic selection changes (`moveSelection`, the anchor restore in `applyTimeline`, and
/// the self-heal in `reanchorToCurrentArticle`) — never from the `selection` setter, which is what
/// the sidebar `List` itself drives on a user click; bumping from there would fight the user's own
/// scrolling. `token` always increments even when `id` repeats, so a second request for the same
/// article is not silently deduplicated by SwiftUI's usual value-equality change detection.
struct SidebarScrollRequest: Equatable {
    let id: String
    let token: Int
}

/// Shared timeline engine for the Mac window: filtering, selection/anchor memory, and the article
/// actions (refresh, star, summarize, force-update, copy link). Mirrors the logic
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
    /// See `SidebarScrollRequest`: consumed by `MacSidebarView` to scroll the selected row into view.
    private(set) var scrollTarget: SidebarScrollRequest?
    var isSummarizing = false
    var toast: ToastMessage?

    private let settings: AppSettings
    private var didRestoreAnchor = false

    private var modelContext: ModelContext?
    private var store: ArticleStore?

    /// Records the anchor for a user-driven selection change. The same `TimelineAnchorWriter` type
    /// iOS's `ReaderAnchorController` uses, so both platforms persist the reading position through
    /// one shared, testable seam: only the `selection` setter and `moveSelection` may call it, never
    /// a programmatic re-anchor.
    let anchorWriter: TimelineAnchorWriter

    var isConfigured: Bool { modelContext != nil }

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        self.anchorWriter = TimelineAnchorWriter(settings: settings)
    }

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
                  let i = TimelinePageIndex.index(of: id, in: filteredArticles),
                  // The sidebar `List(selection:)` binding is re-read (and written back) after any
                  // programmatic move of `currentIndex` — e.g. the anchor restore — so without this
                  // guard, re-selecting the row already at `currentIndex` would still call
                  // `anchorWriter.record` for a no-op selection change.
                  i != currentIndex
            else { return }
            currentIndex = i
            anchorWriter.record(filteredArticles[i])
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
        anchorWriter.record(filteredArticles[next])
        requestScroll(to: filteredArticles[next].identifier)
    }

    /// Bumps `scrollTarget` for a programmatic selection change (never for the `selection` setter's
    /// click path — see `SidebarScrollRequest`).
    private func requestScroll(to id: String) {
        scrollTarget = SidebarScrollRequest(id: id, token: (scrollTarget?.token ?? 0) + 1)
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
        // The canonical UID also carries the feed, so prefer it when it resolves.
        if let i = TimelineUIDIndex.index(of: settings.timelineAnchorSyncUID, in: resolved.articles) {
            currentIndex = i
            settings.timelineAnchorIdentifier = resolved.articles[i].identifier
        }
        didRestoreAnchor = true
        // The launch case: the sidebar has no rows to scroll to until this delivery, so this is the
        // first point a scroll request can be made.
        requestScroll(to: resolved.articles[currentIndex].identifier)
    }

    /// Keeps the displayed article selected across timeline mutations (refresh/reload/retention
    /// cleanup). Prefers the canonical UID over the per-device identifier: the UID also carries the
    /// feed, so it still resolves after a re-import that changed the article's row identity. Falls
    /// back to the identifier when the UID doesn't resolve; the two are written in lockstep by
    /// `TimelineAnchorWriter.record`.
    ///
    /// This runs on every ordinary timeline delivery (most of which leave `currentIndex` unchanged,
    /// since the identifier already resolves to the same row), so it only bumps `scrollTarget` when
    /// the index actually moves — the rare self-heal case — rather than on every delivery.
    private func reanchorToCurrentArticle() {
        let previous = currentIndex
        if let i = TimelineUIDIndex.index(of: settings.timelineAnchorSyncUID, in: filteredArticles) {
            currentIndex = i
            settings.timelineAnchorIdentifier = filteredArticles[i].identifier
        } else if let i = TimelinePageIndex.index(of: settings.timelineAnchorIdentifier, in: filteredArticles) {
            currentIndex = i
        } else {
            return
        }
        if currentIndex != previous {
            requestScroll(to: filteredArticles[currentIndex].identifier)
        }
    }

    /// Keep selection valid after the filter narrows the timeline. When a filter toggle actually
    /// moves the selection (the timeline shrank past the previous `currentIndex`), the reader
    /// detail pane follows automatically (it's indexed by `currentIndex`), but the sidebar `List`
    /// does not re-scroll on its own — so without the guarded `requestScroll` below the reader and
    /// the sidebar selection visibly disagree until the user scrolls manually.
    func clampIndex() {
        let clamped = min(currentIndex, max(0, filteredArticles.count - 1))
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        if filteredArticles.indices.contains(clamped) {
            requestScroll(to: filteredArticles[clamped].identifier)
        }
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
}
