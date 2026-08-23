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

    /// Re-filters `summaries` by the reader's tag/feed/starred/read filter (`TimelineFilterChain`).
    /// Filtering only ever *removes* rows -- it never reorders -- so the result keeps
    /// `ArticleStore`'s canonical `(createdAt, serverID)` order (see `TimelineOrder`), which is what
    /// makes the reader's forward/back navigation symmetric no matter what the user marks read along
    /// the way. The read filter additionally exempts the anchored (currently displayed) article, so
    /// that marking-read-on-display can't pull the open article out of the timeline; see
    /// `ReadFilter.apply`.
    static func recomputeFilter(summaries: [ArticleSummary], settings: AppSettings) -> [ArticleSummary] {
        TimelineFilterChain.apply(to: summaries, settings: settings)
    }

    enum SummarizeResult: Equatable { case saved, failed(AISummaryFailure) }

    /// User-facing copy for a failed summarize, shared by both platforms' toasts. Split by reason
    /// because "Please try again" is actively misleading for the two causes retrying can never fix:
    /// no provider configured, and an article longer than the server's configured AI prompt limit
    /// (whose default, 500 characters, is shorter than any real article body).
    static func summarizeFailureMessage(_ failure: AISummaryFailure) -> String {
        switch failure {
        case .promptTooLong:
            String(localized: "This article is longer than the AI prompt limit on your server. Raise that limit in the server's AI settings and try again.")
        case .noProvider:
            String(localized: "Your server has no AI provider set up yet. Add one in the server's AI settings.")
        case .limitReached:
            String(localized: "Your server has reached its AI request limit. Please try again later.")
        case .providerError:
            String(localized: "Your server's AI provider could not summarize this article. Please try again.")
        case .unavailable(let detail):
            if let detail {
                String(localized: "Could not summarize this article. Please try again. (\(detail))")
            } else {
                String(localized: "Could not summarize this article. Please try again.")
            }
        }
    }

    /// Runs `provider` against `article` and saves the result into the article's block stream. The
    /// caller is expected to have already resolved `provider` (and shown a "not connected" toast
    /// instead of calling this at all when no provider is available) -- see both call sites'
    /// synchronous guard before this.
    ///
    /// The summary is a block (`Block.summary`) at the document's summary slot, the same slot and
    /// same kind the server uses for the summaries it generates itself, so the reader has exactly
    /// one summary to draw however it was produced. It deliberately does NOT write the legacy
    /// `Article.summary` column: that column is read-only now, a fallback for rows summarized
    /// before this change (see `ArticleBlockView.bodyBlocks`).
    static func summarize(
        _ article: Article, using provider: AISummaryProvider, modelContext: ModelContext
    ) async -> SummarizeResult {
        let blocks = article.blocks
        // Summarize the article, not a summary of it. `Article.plainText` includes a summary block's
        // text (it is body content), so re-summarizing would otherwise feed the previous summary
        // back into the model alongside the article.
        let content = BlockParser.plainText(Block.removingSummaries(from: blocks))
        switch await provider.summarize(content: content, title: article.title) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let summary):
            article.blocks = Block.settingSummary(summaryParagraphs(from: summary), in: blocks)
            try? modelContext.save()
            return .saved
        }
    }

    /// A model's summary text split into one paragraph block per blank-line-separated section, so a
    /// multi-paragraph summary keeps its paragraph breaks inside the single summary block.
    static func summaryParagraphs(from text: String) -> [Block] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Block.paragraph([InlineRun(text: $0)]) }
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
