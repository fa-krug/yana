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
    /// one summary to draw however it was produced. There is no summary column on `Article` to write
    /// instead -- the block stream is the only home a summary has.
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

    /// Triggers the server's per-article reload and hands the resulting job to `OperationMonitor`.
    ///
    /// The POST's ack is only a job id, never new content, so there is nothing to report yet: the
    /// monitor is what finds out how the job ended and publishes the outcome. Persisting the
    /// record before returning is deliberate, so an app killed a second later still resumes this
    /// wait on its next launch.
    ///
    /// Returns `false` only when the trigger itself failed.
    @discardableResult
    static func startReload(
        _ article: Article, serverID: Int, client: YanaAPIClient, container: ModelContainer,
        settings: AppSettings, monitor: OperationMonitor = .shared
    ) async -> Bool {
        guard let jobId = try? await ArticleActions(client: client).reload(articleServerID: serverID)
        else { return false }
        let operation = TrackedOperation(kind: .reloadArticle(serverID: serverID), id: jobId,
                                         startedAt: .now)
        settings.trackedOperations.append(operation)
        monitor.track(operation, settings: settings, container: container, client: client,
                      visibleArticle: article)
        return true
    }

    /// Triggers the server's aggregation run over every enabled feed and hands the run to
    /// `OperationMonitor`. Same contract as `startReload`: the ack is a run id, not results.
    @discardableResult
    static func startUpdateAll(
        client: YanaAPIClient, container: ModelContainer, settings: AppSettings,
        monitor: OperationMonitor = .shared
    ) async -> Bool {
        guard let runId = try? await ArticleActions(client: client).updateAll() else { return false }
        let operation = TrackedOperation(kind: .updateAll, id: runId, startedAt: .now)
        settings.trackedOperations.append(operation)
        monitor.track(operation, settings: settings, container: container, client: client)
        return true
    }

    /// The toast to show for a finished `OperationMonitor` operation, shared by every surface that
    /// observes `OperationMonitor.shared.lastOutcomeEvent`: `ReaderScreen` (iOS), `MacRootView`'s
    /// delegate to `TimelineModel.applyOperationOutcome`, and `ArticleListView` while its sheet is
    /// frontmost. Kept in one place because `.failed`/`.unconfirmed` need to read
    /// `TrackedOperation.Kind` to pick the right copy -- an `.updateAll` run has no single article
    /// to name, so it must not reuse the reload-shaped strings, and a duplicated switch drifting
    /// out of sync across three call sites is exactly the failure mode this type exists to avoid.
    static func outcomeToast(_ outcome: OperationOutcome) -> ToastMessage {
        switch outcome {
        case .reloaded(_, let feedName):
            // A reload knows which article it reloaded but not always which feed that article
            // belongs to -- a reload resumed after a relaunch can find the row already pruned, so
            // `feedName` is genuinely `nil`. `RefreshOutcome.message(newCount: 0, feedName: nil)`
            // renders that as "No new articles.", which is an Update All result reported for a
            // successful single-article reload. So the nameless case gets copy of its own.
            guard let feedName else {
                return ToastMessage(text: String(localized: "Reloaded this article."))
            }
            return ToastMessage(text: RefreshOutcome.message(newCount: 0, feedName: feedName))
        case .updated(let newCount):
            return ToastMessage(text: RefreshOutcome.message(newCount: newCount, feedName: nil))
        case .failed(.reloadArticle):
            return ToastMessage(
                text: String(localized: "Could not reload this article. Please try again."),
                style: .error
            )
        case .failed(.updateAll):
            return ToastMessage(
                text: String(localized: "Could not check for updates. Please try again."),
                style: .error
            )
        case .unconfirmed(.reloadArticle):
            return ToastMessage(text: String(localized: "The server did not confirm this finished, so this might not be the newest version."))
        case .unconfirmed(.updateAll):
            return ToastMessage(text: String(localized: "The server did not confirm this update finished, so some new articles might still be missing."))
        }
    }

    /// Whether reacting to this outcome should bump `reloadToken` to re-render the currently
    /// visible article page. Only a `.reloadArticle` operation ever touches the open article's own
    /// content -- an `.updateAll` run never writes to it directly (any new articles it produced
    /// arrive through the ordinary sync pull), so bumping the token for one would re-render the
    /// page for no reason.
    static func outcomeRefreshesVisiblePage(_ outcome: OperationOutcome) -> Bool {
        switch outcome {
        case .reloaded: true
        case .unconfirmed(.reloadArticle): true
        case .updated, .failed, .unconfirmed(.updateAll): false
        }
    }
}
