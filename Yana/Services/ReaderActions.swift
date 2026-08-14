import Foundation
import SwiftData

/// Reader-action orchestration shared by the iOS reader (`ReaderScreen` in `ReaderHostView.swift`)
/// and the Mac timeline (`Reader/Mac/TimelineModel.swift`), which independently implemented the
/// identical server-interaction sequencing for summarize/reload/update. Deliberately scoped to
/// just that sequencing -- provider/client resolution, the actual async calls, and the outcome
/// decision -- and NOT to state ownership: `toast`/`isSummarizing`/`reloadToken` stay wherever each
/// platform already keeps them (iOS: `ReaderScreen`'s local `@State`; Mac: `TimelineModel`'s
/// `@Observable` properties), and haptics stay iOS-only, exactly as before this extraction. Unifying
/// that state ownership too would be a much larger, riskier change than deduplicating this
/// orchestration needs; each call site still does its own early guards (pairing/serverID checks)
/// and applies the result to its own state, so behavior is unchanged, just no longer duplicated.
@MainActor
enum ReaderActions {
    /// Whether AI summarization is currently usable. `.server` mode degrades gracefully on its own
    /// but still needs an actual pairing to reach the server; `.appleIntelligence` only needs
    /// on-device availability, independent of pairing.
    static func aiReady(mode: AIMode) -> Bool {
        switch mode {
        case .server: AuthenticatedClient.current() != nil
        case .appleIntelligence: AISummaryReadiness.isReady(mode: .appleIntelligence)
        }
    }

    /// Re-filters `summaries` by the reader's tag/feed/starred filter, then pins the currently-
    /// displayed article's position (see `TimelinePinning`) so marking it read doesn't reshuffle
    /// the timeline out from under the user.
    static func recomputeFilter(summaries: [ArticleSummary], settings: AppSettings) -> [ArticleSummary] {
        let byTag = TagFilter.apply(
            to: summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        return TimelinePinning.apply(
            to: canonical, pinning: settings.timelineAnchorIdentifier, pinningServerID: settings.timelineAnchorServerID
        )
    }

    enum SummarizeResult { case saved, failed }

    /// Runs `provider` against `article` and saves the result. The caller is expected to have
    /// already resolved `provider` (and shown a "not connected" toast instead of calling this at
    /// all when no provider is available) -- see both call sites' synchronous guard before this.
    static func summarize(
        _ article: Article, using provider: AISummaryProvider, modelContext: ModelContext
    ) async -> SummarizeResult {
        guard let summary = await provider.summarize(content: article.plainText, title: article.title) else {
            return .failed
        }
        article.summary = summary
        try? modelContext.save()
        return .saved
    }

    enum ForceUpdateResult { case cancelled, applied(feedName: String?), failed }

    /// Triggers the server's per-article reload, then re-fetches its content directly via
    /// `UpdateAndSync.pollForReloadedContent`. Deliberately does NOT go through `SyncEngine`'s
    /// generic `hasContent`-gated backfill -- a premature backfill fetch during the poll window
    /// could permanently lock out any later retry of this exact article. Caller must already have
    /// confirmed pairing and a `serverID` before calling, and should run this from inside
    /// `UpdateActivity.shared.restart` so its in-flight-task-cancellation contract still applies.
    static func forceUpdateArticle(
        _ article: Article, serverID: Int, client: YanaAPIClient, container: ModelContainer
    ) async -> ForceUpdateResult {
        do {
            let jobId = try await ArticleActions(client: client).reload(articleServerID: serverID)
            guard !Task.isCancelled else { return .cancelled }
            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: jobId, articleServerID: serverID, container: container, client: client,
                visibleArticle: article
            )
            guard !Task.isCancelled else { return .cancelled }
            return applied ? .applied(feedName: article.feed?.name) : .failed
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            return .failed
        }
    }

    enum TriggerRefreshResult { case cancelled, applied(newCount: Int), failed }

    /// "Update" only triggers the server's aggregation run (`ArticleActions.updateAll()`); the run
    /// itself happens server-side and asynchronously, so this follows up with `UpdateAndSync`'s
    /// bounded poll of `SyncEngine.sync()` to actually pull in whatever the run produced. Caller
    /// must already have confirmed pairing before calling, and should run this from inside
    /// `UpdateActivity.shared.restart`.
    static func triggerRefresh(
        client: YanaAPIClient, container: ModelContainer, settings: AppSettings
    ) async -> TriggerRefreshResult {
        do {
            let runId = try await ArticleActions(client: client).updateAll()
            guard !Task.isCancelled else { return .cancelled }
            let result = await UpdateAndSync.pollForFreshContent(
                runId: runId, container: container, client: client, settings: settings
            )
            guard !Task.isCancelled else { return .cancelled }
            return .applied(newCount: result.newCount)
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            return .failed
        }
    }
}
