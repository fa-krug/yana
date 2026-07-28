import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A one-shot request to scroll the Mac sidebar to a specific row. `TimelineModel` bumps this only
/// from programmatic selection changes (`moveSelection`, the anchor restore in `applyTimeline`, a
/// remote anchor landing via `jumpToSyncedTimelinePosition`, and the self-heal in
/// `reanchorToCurrentArticle`) — never from the `selection` setter, which is what the sidebar
/// `List` itself drives on a user click; bumping from there would fight the user's own scrolling.
/// `token` always increments even when `id` repeats, so a second request for the same article
/// (e.g. the launch anchor restore immediately followed by a remote anchor for that same article)
/// is not silently deduplicated by SwiftUI's usual value-equality change detection.
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

    /// Notification center the synced-anchor observer registers on. Injectable so tests can post to
    /// a private center instead of racing other suites on `.default` (mirrors `LibraryRevision`).
    private let notificationCenter: NotificationCenter
    private var anchorObserver: NSObjectProtocol?

    /// Records + pushes a changed anchor to iCloud KVS (coalesced). The same `TimelineAnchorWriter`
    /// type iOS's `ReaderAnchorController` uses, so the no-ping-pong guarantee is asserted against
    /// one shared, testable seam on both platforms: `jumpToSyncedTimelinePosition` must never call
    /// `anchorWriter.record`, only the user-driven `selection` setter and `moveSelection` may.
    let anchorWriter: TimelineAnchorWriter

    var isConfigured: Bool { modelContext != nil }

    init(settings: AppSettings = AppSettings(), notificationCenter: NotificationCenter = .default) {
        self.settings = settings
        self.notificationCenter = notificationCenter
        self.anchorWriter = TimelineAnchorWriter(settings: settings)
    }

    func configure(modelContext: ModelContext, store: ArticleStore) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        self.store = store
        observeSyncedAnchor()
    }

    isolated deinit {
        if let anchorObserver { notificationCenter.removeObserver(anchorObserver) }
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
        // A synced anchor (canonical UID) resolves exactly across devices; prefer it when present.
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
    /// cleanup). Prefers the canonical synced UID over the per-device identifier: a remote anchor
    /// may have arrived for an article that hadn't synced to this device yet — the *common* case,
    /// since KVS anchor propagation is typically faster than the CloudKit article import catching
    /// up — and once that article does arrive on a later delivery (this method runs again from
    /// `applyTimeline`), this is what finally moves the selection: `timelinePositionDidChange` won't
    /// re-fire, since the UID hasn't changed since it arrived. Without this self-heal the position
    /// would only catch up on the next launch — close to the very symptom this task exists to fix.
    /// Falls back to the identifier when the UID doesn't resolve either; the two are written in
    /// lockstep by every local write (`TimelineAnchorWriter.record`), so they only disagree in
    /// exactly this pending-sync window.
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

    /// Keep selection valid after the filter narrows the timeline.
    func clampIndex() {
        currentIndex = min(currentIndex, max(0, filteredArticles.count - 1))
    }

    // MARK: - Synced anchor (remote apply)

    /// Registers the observer that lets a remote timeline anchor move the Mac selection.
    /// Previously the Mac side had no observer at all — `AppSettings.timelinePositionDidChange` was
    /// only ever watched on iOS — so a position synced from another device never reached this
    /// window. Idempotent; called once from `configure`.
    private func observeSyncedAnchor() {
        guard anchorObserver == nil else { return }
        anchorObserver = notificationCenter.addObserver(
            forName: AppSettings.timelinePositionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpToSyncedTimelinePosition() }
        }
    }

    /// Moves the Mac selection to the synced timeline anchor article. This is the remote-anchor
    /// apply path, so it also bumps `scrollTarget` (see `SidebarScrollRequest`) to scroll the
    /// sidebar to the newly selected row, alongside the other programmatic-selection paths.
    ///
    /// Deliberately does **not** go through the `selection` setter — it sets `currentIndex` and
    /// `timelineAnchorIdentifier` directly, so applying a remote anchor can never call
    /// `anchorWriter.record` and loop the write straight back to the device that sent it (the
    /// "no ping-pong" requirement: only user-driven selection changes push — see
    /// `TimelineModelTests` for the assertion). Ignored when the anchored article hasn't synced to
    /// this device yet (`TimelineUIDIndex.index` returns `nil`).
    func jumpToSyncedTimelinePosition() {
        guard didRestoreAnchor,
              let i = TimelineUIDIndex.index(of: settings.timelineAnchorSyncUID, in: filteredArticles)
        else { return }
        currentIndex = i
        settings.timelineAnchorIdentifier = filteredArticles[i].identifier
        requestScroll(to: filteredArticles[i].identifier)
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
