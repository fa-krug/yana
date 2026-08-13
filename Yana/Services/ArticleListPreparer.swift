import Foundation

/// Continuously maintains the reader's browsing-mode article list (tag/feed/starred-filtered,
/// pinned to the current article — the same chain `ReaderScreen.recomputeFilter` applies to its
/// own pager) so the article list sheet (`ArticleListView`) has it ready the instant it opens,
/// rather than computing it as part of the sheet's own first render.
///
/// This runs independent of any particular view, in the background of the app's lifecycle:
/// - `ArticleStore.summaries` changes are picked up via `Observation`'s `withObservationTracking`,
///   re-armed after every fire (the standard pattern for observing an `@Observable` property
///   outside of a SwiftUI view body).
/// - Filter changes are picked up via `UserDefaults.didChangeNotification`, not by re-reading
///   `AppSettings` inside a view's `body`. `AppSettings` instances don't observe each other — every
///   view constructs its own over the same `UserDefaults` — so a view that only recomputes when
///   *its own* render happens to run again would miss a filter changed via a different instance
///   (e.g. `TagFilterView` presented from the list's own filter button, which never forces the
///   list's ancestor to re-render). Listening at the `UserDefaults` layer instead catches every
///   write regardless of which instance made it.
@MainActor
@Observable
final class ArticleListPreparer {
    private(set) var browsingArticles: [ArticleSummary] = []

    @ObservationIgnored private let settings = AppSettings()
    @ObservationIgnored private var store: ArticleStore?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    /// Begin observing `store` and `UserDefaults`. Idempotent; call once at launch.
    func start(store: ArticleStore) {
        guard defaultsObserver == nil else { return }
        self.store = store
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recompute() }
        }
        observeStore()
        recompute()
    }

    private func observeStore() {
        guard let store else { return }
        withObservationTracking {
            _ = store.summaries
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.recompute()
                self?.observeStore()
            }
        }
    }

    private func recompute() {
        guard let store else { return }
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        let next = TimelinePinning.apply(to: canonical, pinning: settings.timelineAnchorIdentifier)
        guard next != browsingArticles else { return }
        browsingArticles = next
    }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }
}
