import Foundation
import SwiftData

/// Loads the lightweight article index off the main thread. `@ModelActor` gives it a private
/// `ModelContext`; it maps to `Sendable` `ArticleSummary` values that cross back to the main actor.
@ModelActor
actor ArticleSummaryLoader {
    func load() throws -> [ArticleSummary] {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        // Only the light columns; HTML (`content`/`rawContent`/`summary`) stays unfetched.
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt]
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return try modelContext.fetch(descriptor).map(ArticleSummary.init)
    }

    /// Anchor-centered slice for the cold-cache fast path: the ~`2*radius+1` articles around the
    /// saved anchor (inclusive), ascending. Falls back to the newest `2*radius+1` when there is no
    /// anchor or it is gone. Same light columns / prefetch as `load()`.
    func loadWindow(around anchorID: String?, radius: Int) throws -> [ArticleSummary] {
        // The window splits on `createdAt` (`>= anchorDate` newer, `< anchorDate` older). Under
        // exact-timestamp ties the anchor may not land in the truncated window; that is acceptable
        // and self-healing — this is only the transient cold-cache first-paint set, and the full
        // load (ms later) plus reanchor-by-identifier resolves the true position regardless.
        if let anchorID, let anchorDate = try anchorCreatedAt(for: anchorID) {
            var newerD = lightDescriptor(
                predicate: #Predicate { $0.createdAt >= anchorDate }, order: .forward
            )
            newerD.fetchLimit = radius + 1
            let newer = try modelContext.fetch(newerD)

            var olderD = lightDescriptor(
                predicate: #Predicate { $0.createdAt < anchorDate }, order: .reverse
            )
            olderD.fetchLimit = radius
            let older = try modelContext.fetch(olderD)

            return (Array(older.reversed()) + newer).map(ArticleSummary.init)
        }

        var newestD = lightDescriptor(predicate: nil, order: .reverse)
        newestD.fetchLimit = 2 * radius + 1
        return try modelContext.fetch(newestD).reversed().map(ArticleSummary.init)
    }

    private func anchorCreatedAt(for identifier: String) throws -> Date? {
        var d = FetchDescriptor<Article>(
            predicate: #Predicate { $0.identifier == identifier },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        d.fetchLimit = 1
        d.propertiesToFetch = [\.createdAt]
        return try modelContext.fetch(d).first?.createdAt
    }

    /// A `createdAt`-sorted descriptor restricted to the light timeline columns, with `feed`/`tags`
    /// prefetched — the same shape `load()` uses, factored out for the windowed fetches.
    private func lightDescriptor(
        predicate: Predicate<Article>?, order: SortOrder
    ) -> FetchDescriptor<Article> {
        var d = FetchDescriptor<Article>(
            predicate: predicate, sortBy: [SortDescriptor(\.createdAt, order: order)]
        )
        d.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt]
        d.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return d
    }
}

/// Single source of truth for the timeline/list dataset. On cold start it paints from the disk
/// cache (warm) or a small anchor-centered window (cold cache), then reconciles to the full DB
/// index and keeps in sync with every `ModelContext` save.
@MainActor
@Observable
final class ArticleStore {
    private(set) var summaries: [ArticleSummary] = []
    private(set) var hasLoaded = false

    /// Half-width of the cold-cache window; ~`2*radius+1` articles around the anchor.
    private static let windowRadius = 25

    private let container: ModelContainer
    private let cache: SummaryIndexCache
    private let anchorProvider: () -> String?
    private var observer: NSObjectProtocol?
    private var debounce: Task<Void, Never>?

    init(
        container: ModelContainer,
        cache: SummaryIndexCache = .shared,
        anchorProvider: @escaping () -> String? = { AppSettings().timelineAnchorIdentifier }
    ) {
        self.container = container
        self.cache = cache
        self.anchorProvider = anchorProvider
    }

    /// Begin observing saves and run the first load. Idempotent.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        Task { await bootstrap() }
    }

    /// Cold-start path: publish a fast first dataset (disk cache when present, else an
    /// anchor-centered DB window), flip `hasLoaded`, then reconcile to the authoritative full load.
    func bootstrap() async {
        if let cached = await cache.load() {
            summaries = cached
            hasLoaded = true
        } else {
            let loader = ArticleSummaryLoader(modelContainer: container)
            let window = (try? await loader.loadWindow(
                around: anchorProvider(), radius: Self.windowRadius
            )) ?? []
            summaries = window
            hasLoaded = true
        }
        await fullLoad()
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    /// Reload the full index from the DB and publish it. Awaited directly by tests.
    func refreshNow() async {
        await fullLoad()
        hasLoaded = true
    }

    /// Fetch the entire light index off-main, publish it, and rewrite the disk cache.
    private func fullLoad() async {
        let loader = ArticleSummaryLoader(modelContainer: container)
        let all = (try? await loader.load()) ?? []
        summaries = all
        await cache.save(all)
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
