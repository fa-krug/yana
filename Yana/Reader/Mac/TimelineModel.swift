import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A one-shot request to scroll the Mac sidebar to a specific row. `TimelineModel` bumps this only
/// from programmatic selection changes (`moveSelection`, the anchor restore in `applyTimeline`, a
/// remote position landing via `jumpToSyncedTimelinePosition`, and the self-heal in
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
    /// Server-side article id to view in `ManagementWebView`, set by `openOnServer`; `nil` means
    /// the sheet `MacRootView` binds to this is dismissed.
    var openOnServerArticleID: Int?

    private let settings: AppSettings
    private var didRestoreAnchor = false

    private var modelContext: ModelContext?
    private var store: ArticleStore?



    /// Records the anchor locally and pushes it to the server (debounced) via `ReadingPositionSync`.
    /// The same `TimelineAnchorWriter` type iOS's `ReaderAnchorController` uses, so the
    /// no-ping-pong guarantee is asserted against one shared, testable seam on both platforms:
    /// `jumpToSyncedTimelinePosition` must never call `anchorWriter.record`, only the user-driven
    /// `selection` setter and `moveSelection` may.
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
                  // programmatic move of `currentIndex` — e.g. `jumpToSyncedTimelinePosition` — so
                  // without this guard, re-selecting the row already at `currentIndex` would still
                  // call `anchorWriter.record` for a no-op selection change. Worst case that's a
                  // stale anchor pushed back to the server moments after a newer one arrived, which
                  // last-writer-wins could then drag another device backwards.
                  i != currentIndex
            else { return }
            currentIndex = i
            anchorWriter.record(filteredArticles[i])
            if let modelContext, let article = resolve(filteredArticles[i]) {
                ArticleWrites.markRead(article, modelContext: modelContext)
            }
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
        if let modelContext, let article = resolve(filteredArticles[next]) {
            ArticleWrites.markRead(article, modelContext: modelContext)
        }
        requestScroll(to: filteredArticles[next].identifier)
    }

    /// Bumps `scrollTarget` for a programmatic selection change (never for the `selection` setter's
    /// click path — see `SidebarScrollRequest`).
    private func requestScroll(to id: String) {
        scrollTarget = SidebarScrollRequest(id: id, token: (scrollTarget?.token ?? 0) + 1)
    }

    /// `.server` mode degrades gracefully on its own but still needs an actual pairing to reach
    /// the server; `.appleIntelligence` only needs on-device availability, independent of pairing.
    var aiReady: Bool {
        switch settings.aiMode {
        case .server: hasServer
        case .appleIntelligence: AISummaryReadiness.isReady(mode: .appleIntelligence)
        }
    }

    // MARK: - Filtering / anchor (mirrors ReaderScreen)

    func recomputeFilter() {
        guard let store else { return }
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        filteredArticles = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
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
            starredOnly: settings.starredOnly,
            anchorIdentifier: settings.timelineAnchorIdentifier
        )
        filteredArticles = resolved.articles
        guard !resolved.articles.isEmpty else { return }
        currentIndex = jumpToSyncedTimelinePosition(in: resolved.articles) ?? resolved.anchorIndex

        didRestoreAnchor = true
        // The launch case: the sidebar has no rows to scroll to until this delivery, so this is the
        // first point a scroll request can be made.
        requestScroll(to: resolved.articles[currentIndex].identifier)
    }

    /// Applies a reading position pulled from another paired device (see
    /// `AppSettings.pendingRemoteReadingPosition`), if it resolves against `articles`. Consumes the
    /// pending value either way (resolved or not) so a stale/unsyncable remote position isn't
    /// retried forever. Call ONLY from `applyTimeline`'s first-load branch -- never mid-session,
    /// which would yank the user off the article they're actively reading. Mirrors
    /// `ReaderAnchorController.jumpToSyncedTimelinePosition` on iOS; see its doc comment for why
    /// this must never call `anchorWriter.record`.
    private func jumpToSyncedTimelinePosition(in articles: [ArticleSummary]) -> Int? {
        guard let articleID = settings.pendingRemoteReadingPosition else { return nil }
        settings.pendingRemoteReadingPosition = nil
        guard let index = articles.firstIndex(where: { $0.serverID == articleID }) else { return nil }
        settings.timelineAnchorIdentifier = articles[index].identifier
        return index
    }

    /// Keeps the displayed article selected across timeline mutations (refresh/reload/retention
    /// cleanup).
    private func reanchorToCurrentArticle() {
        let previous = currentIndex
        if let i = TimelinePageIndex.index(of: settings.timelineAnchorIdentifier, in: filteredArticles) {
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

    /// Toggles locally right away (optimistic) via `ArticleWrites`; queued for retry rather than
    /// rolled back on failure. Silently local-only when not paired.
    func toggleStar(_ article: Article) {
        guard let modelContext else { return }
        ArticleWrites.toggleStar(article, modelContext: modelContext)
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

    /// True when a server is paired, gating the "Open on Server" action alongside a per-article
    /// `serverID` check at the call site.
    var hasServer: Bool { AuthenticatedClient.current() != nil }

    func openOnServer(_ article: Article) {
        guard AuthenticatedClient.current() != nil, let serverID = article.serverID else { return }
        openOnServerArticleID = serverID
    }

    func summarize(_ article: Article) {
        guard let modelContext, !isSummarizing else { return }
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
            let summary = await provider.summarize(content: article.plainText, title: article.title)
            isSummarizing = false
            if let summary {
                article.summary = summary
                try? modelContext.save()
                self.reloadToken += 1
            } else {
                self.toast = ToastMessage(
                    text: String(localized: "Could not summarize this article. Please try again."),
                    style: .error
                )
            }
        }
    }

    /// Triggers the server's per-article reload, then re-fetches its content directly via
    /// `UpdateAndSync.pollForReloadedContent`. See `ReaderScreen.forceUpdateArticle` (iOS) and that
    /// method's doc comment for why this deliberately does NOT go through `SyncEngine`'s generic
    /// `hasContent`-gated backfill (an earlier version of this code did, and a premature backfill
    /// fetch during the poll window could permanently lock out any later retry of this article).
    func forceUpdateArticle(_ article: Article) {
        guard let modelContext,
              let client = AuthenticatedClient.current(),
              let serverID = article.serverID
        else { return }
        let feedName = article.feed?.name
        UpdateActivity.shared.restart {
            do {
                let jobId = try await ArticleActions(client: client).reload(articleServerID: serverID)
                guard !Task.isCancelled else { return }
                let applied = await UpdateAndSync.pollForReloadedContent(
                    jobId: jobId, articleServerID: serverID, container: modelContext.container, client: client,
                    visibleArticle: article
                )
                guard !Task.isCancelled else { return }
                if applied {
                    self.reloadToken += 1
                    self.toast = ToastMessage(text: RefreshOutcome.message(newCount: 0, feedName: feedName))
                } else {
                    self.toast = ToastMessage(
                        text: String(localized: "Could not reload this article. Please try again."),
                        style: .error
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.toast = ToastMessage(
                    text: String(localized: "Could not reload this article. Please try again."),
                    style: .error
                )
            }
        }
    }

    /// "Update" only triggers the server's aggregation run (`ArticleActions.updateAll()`); the run
    /// itself happens server-side and asynchronously, so this follows up with `UpdateAndSync`'s
    /// bounded poll of `SyncEngine.sync()` to actually pull in whatever the run produced.
    func triggerRefresh() {
        guard let modelContext else { return }
        guard let client = AuthenticatedClient.current() else {
            toast = ToastMessage(text: String(localized: "Not connected to a server."), style: .error)
            return
        }
        UpdateActivity.shared.restart {
            do {
                let runId = try await ArticleActions(client: client).updateAll()
                guard !Task.isCancelled else { return }
                let result = await UpdateAndSync.pollForFreshContent(
                    runId: runId, container: modelContext.container, client: client, settings: self.settings
                )
                guard !Task.isCancelled else { return }
                self.toast = ToastMessage(text: RefreshOutcome.message(newCount: result.newCount, feedName: nil))
            } catch {
                guard !Task.isCancelled else { return }
                self.toast = ToastMessage(
                    text: String(localized: "Could not check for updates. Please try again."),
                    style: .error
                )
            }
        }
    }
}
