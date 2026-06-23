# Cold-Start Summary-Index Cache + Anchor-Centered Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the reader interactive at the saved anchor on cold start by serving the article index from a disk cache (warm launch) or a small anchor-centered DB window (cold cache), instead of waiting for a full-library off-main fetch.

**Architecture:** `ArticleStore.bootstrap()` publishes `summaries` from `SummaryIndexCache` (disk) when present, else from `ArticleSummaryLoader.loadWindow(...)` (a ~51-article slice centered on the anchor), flips `hasLoaded` immediately, then reconciles to the authoritative full DB load and rewrites the cache. A stale-`persistentID` safety net lets the reader resolve an `Article` by `identifier` when the cached id misses.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftData (`@ModelActor`, `FetchDescriptor`, `#Predicate`), Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform: iOS 26.0+ (iPhone and iPad); deploy/build via simulator `iPhone 17`.
- Swift 6 strict concurrency; annotate main-actor types `@MainActor`; cross-actor values must be `Sendable`.
- Tests use Swift Testing (`@Test`, `#expect`) and are `@MainActor`; SwiftData tests use `ModelConfiguration(isStoredInMemoryOnly: true)`.
- Sources are directory-globbed in `project.yml` (`path: Yana`, `path: YanaTests`); run `xcodegen generate` after adding any new file so the project picks it up.
- No new user-facing strings in this work (no `Localizable.xcstrings` changes required).
- Build command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- Run a single Swift Testing test: append `-only-testing:YanaTests/<SuiteStruct>/<method>`.

---

### Task 1: `ArticleSummary` Codable + `SummaryIndexCache`

**Files:**
- Modify: `Yana/Models/ArticleSummary.swift` (add `Codable` to the conformance list)
- Create: `Yana/Services/SummaryIndexCache.swift`
- Test: `YanaTests/SummaryIndexCacheTests.swift`

**Interfaces:**
- Consumes: `ArticleSummary` (existing struct; `init(_ article: Article)`).
- Produces:
  - `extension ArticleSummary: Codable` (synthesized).
  - `actor SummaryIndexCache` with:
    - `static let shared: SummaryIndexCache`
    - `init(fileURL: URL? = nil)` — defaults to `<Caches>/summary-index.plist`
    - `func load() -> [ArticleSummary]?`
    - `func save(_ summaries: [ArticleSummary])`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/SummaryIndexCacheTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SummaryIndexCache")
struct SummaryIndexCacheTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func makeSummary(_ id: String, in context: ModelContext) throws -> ArticleSummary {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: id)
        article.feed = feed
        context.insert(feed); context.insert(article)
        try context.save()   // permanent persistentModelID so the Codable round-trip is stable
        return ArticleSummary(article)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-test-\(UUID().uuidString).plist")
    }

    @Test func roundTripsSummaries() async throws {
        let context = try makeContainer().mainContext
        let summaries = [try makeSummary("a", in: context), try makeSummary("b", in: context)]
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SummaryIndexCache(fileURL: url)
        await cache.save(summaries)
        let loaded = await cache.load()

        #expect(loaded?.map(\.identifier) == ["a", "b"])
        #expect(loaded?.first?.feedName == "Acme")
    }

    @Test func loadReturnsNilWhenAbsent() async throws {
        let cache = SummaryIndexCache(fileURL: tempURL())
        let loaded = await cache.load()
        #expect(loaded == nil)
    }

    @Test func loadReturnsNilWhenCorrupt() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a plist".utf8).write(to: url)

        let cache = SummaryIndexCache(fileURL: url)
        let loaded = await cache.load()
        #expect(loaded == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build-for-testing`
Expected: FAIL to compile — `cannot find 'SummaryIndexCache' in scope` and/or `ArticleSummary` not `Codable`.

- [ ] **Step 3: Make `ArticleSummary` Codable**

In `Yana/Models/ArticleSummary.swift`, change the declaration line:

```swift
struct ArticleSummary: Identifiable, Sendable, Hashable {
```

to:

```swift
struct ArticleSummary: Identifiable, Sendable, Hashable, Codable {
```

(All stored properties are `Codable`: `PersistentIdentifier`, `String`, `String?`, `Date`, `Set<String>`, `Bool`. The custom `init(_ article: Article)` coexists with the synthesized `init(from:)`.)

- [ ] **Step 4: Create `SummaryIndexCache`**

Create `Yana/Services/SummaryIndexCache.swift`:

```swift
import Foundation

/// Persists the lightweight article index to disk so a warm cold-start can paint the timeline
/// without any SwiftData fetch. Lives in Caches (a derived artifact; if purged, `ArticleStore`
/// falls back to an anchor-centered DB window). An `actor` so all file IO runs off the main actor.
actor SummaryIndexCache {
    static let shared = SummaryIndexCache()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.fileURL = dir.appendingPathComponent("summary-index.plist")
        }
    }

    /// The cached index, or `nil` when the file is absent or fails to decode (corruption / a
    /// format change). A `nil` result is a clean signal to fall back to the DB — never a crash.
    func load() -> [ArticleSummary]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode([ArticleSummary].self, from: data)
    }

    /// Replace the cached index. Failures are swallowed: the cache is best-effort and the DB
    /// remains the source of truth.
    func save(_ summaries: [ArticleSummary]) {
        guard let data = try? PropertyListEncoder().encode(summaries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Regenerate project and run the tests**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SummaryIndexCache`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/ArticleSummary.swift Yana/Services/SummaryIndexCache.swift YanaTests/SummaryIndexCacheTests.swift project.yml
git commit -m "feat(cache): persistable ArticleSummary + SummaryIndexCache"
```

---

### Task 2: Anchor-centered window fetch on `ArticleSummaryLoader`

**Files:**
- Modify: `Yana/Services/ArticleStore.swift` (add `loadWindow` + a private light-descriptor helper to the `ArticleSummaryLoader` actor)
- Test: `YanaTests/ArticleSummaryLoaderTests.swift`

**Interfaces:**
- Consumes: existing `@ModelActor actor ArticleSummaryLoader` with `func load() throws -> [ArticleSummary]`.
- Produces: `func loadWindow(around anchorID: String?, radius: Int) throws -> [ArticleSummary]` — returns an ascending (oldest→new) slice centered on the anchor row (inclusive); when `anchorID` is `nil` or not found, returns the newest `2*radius + 1` articles ascending.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSummaryLoaderTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSummaryLoader.loadWindow")
struct ArticleSummaryLoaderTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    /// Insert `count` articles "a0"…"a{count-1}" with strictly increasing createdAt.
    private func seed(_ count: Int, into context: ModelContext) {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f")
        context.insert(feed)
        for i in 0..<count {
            let a = Article(title: "a\(i)", identifier: "a\(i)", url: "a\(i)")
            a.feed = feed
            a.createdAt = Date(timeIntervalSince1970: TimeInterval(i + 1))
            context.insert(a)
        }
    }

    @Test func windowIsCenteredOnAnchorAndIncludesIt() async throws {
        let container = try makeContainer()
        seed(100, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: "a50", radius: 5)
        let ids = window.map(\.identifier)

        #expect(ids == ["a45","a46","a47","a48","a49","a50","a51","a52","a53","a54","a55"])
    }

    @Test func fallsBackToNewestWhenAnchorMissing() async throws {
        let container = try makeContainer()
        seed(10, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: "does-not-exist", radius: 2)

        // newest 2*2+1 = 5, ascending
        #expect(window.map(\.identifier) == ["a5","a6","a7","a8","a9"])
    }

    @Test func fallsBackToNewestWhenAnchorNil() async throws {
        let container = try makeContainer()
        seed(4, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: nil, radius: 10)

        // fewer rows than the window: all of them, ascending
        #expect(window.map(\.identifier) == ["a0","a1","a2","a3"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build-for-testing`
Expected: FAIL to compile — `value of type 'ArticleSummaryLoader' has no member 'loadWindow'`.

- [ ] **Step 3: Implement `loadWindow` + helper**

In `Yana/Services/ArticleStore.swift`, inside the `ArticleSummaryLoader` actor (right after the existing `load()` method), add:

```swift
    /// Anchor-centered slice for the cold-cache fast path: the ~`2*radius+1` articles around the
    /// saved anchor (inclusive), ascending. Falls back to the newest `2*radius+1` when there is no
    /// anchor or it is gone. Same light columns / prefetch as `load()`.
    func loadWindow(around anchorID: String?, radius: Int) throws -> [ArticleSummary] {
        if let anchorID, let anchorDate = try anchorCreatedAt(for: anchorID) {
            // newer-or-equal: includes the anchor itself; ascending, capped at radius+1.
            var newerD = lightDescriptor(
                predicate: #Predicate { $0.createdAt >= anchorDate }, order: .forward
            )
            newerD.fetchLimit = radius + 1
            let newer = try modelContext.fetch(newerD)

            // older: strictly-older articles, fetched newest-first then reversed to ascending.
            var olderD = lightDescriptor(
                predicate: #Predicate { $0.createdAt < anchorDate }, order: .reverse
            )
            olderD.fetchLimit = radius
            let older = try modelContext.fetch(olderD)

            return (Array(older.reversed()) + newer).map(ArticleSummary.init)
        }

        // No usable anchor: newest 2*radius+1, fetched newest-first then reversed to ascending.
        var newestD = lightDescriptor(predicate: nil, order: .reverse)
        newestD.fetchLimit = 2 * radius + 1
        return try modelContext.fetch(newestD).reversed().map(ArticleSummary.init)
    }

    private func anchorCreatedAt(for identifier: String) throws -> Date? {
        var d = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
        d.fetchLimit = 1
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
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummaryLoader.loadWindow`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleStore.swift YanaTests/ArticleSummaryLoaderTests.swift project.yml
git commit -m "feat(store): anchor-centered window fetch on ArticleSummaryLoader"
```

---

### Task 3: `ArticleStore` two-phase bootstrap (cache → full / window → full)

**Files:**
- Modify: `Yana/Services/ArticleStore.swift` (`ArticleStore` class: injectable cache + anchor provider; `bootstrap()`; `fullLoad()`; rewire `start()` and `refreshNow()` to write the cache)
- Test: `YanaTests/ArticleStoreTests.swift` (inject a temp cache; add cache-path and window-path tests)

**Interfaces:**
- Consumes: `SummaryIndexCache` (Task 1), `ArticleSummaryLoader.loadWindow` (Task 2).
- Produces: `ArticleStore.init(container:cache:anchorProvider:)` with defaults `cache: .shared`, `anchorProvider: { AppSettings().timelineAnchorIdentifier }`; `func bootstrap() async`; unchanged public `summaries` / `hasLoaded` / `refreshNow()` / `start()` surface.

- [ ] **Step 1: Update existing tests to inject a temp cache, and add new tests**

Replace the body of `YanaTests/ArticleStoreTests.swift` with:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleStore")
struct ArticleStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    private func tempCache() -> SummaryIndexCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-test-\(UUID().uuidString).plist")
        return SummaryIndexCache(fileURL: url)
    }

    private func insertArticle(_ id: String, into context: ModelContext, createdAt: Date) {
        let feed = Feed(name: "Acme", aggregatorType: .feedContent, identifier: "f-\(id)")
        let article = Article(title: id, identifier: id, url: id)
        article.feed = feed
        article.createdAt = createdAt
        context.insert(feed); context.insert(article)
    }

    private func seed(_ count: Int, into context: ModelContext) {
        for i in 0..<count {
            insertArticle("a\(i)", into: context, createdAt: Date(timeIntervalSince1970: TimeInterval(i + 1)))
        }
    }

    @Test func loadsExistingArticlesChronologically() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        insertArticle("old", into: context, createdAt: Date(timeIntervalSince1970: 1))
        insertArticle("new", into: context, createdAt: Date(timeIntervalSince1970: 2))
        try context.save()

        let store = ArticleStore(container: container, cache: tempCache())
        await store.refreshNow()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.map(\.identifier) == ["old", "new"])
    }

    @Test func reflectsInsertOnRefresh() async throws {
        let container = try makeContainer()
        let store = ArticleStore(container: container, cache: tempCache())
        await store.refreshNow()
        #expect(store.summaries.isEmpty)

        insertArticle("x", into: container.mainContext, createdAt: .now)
        try container.mainContext.save()
        await store.refreshNow()

        #expect(store.summaries.map(\.identifier) == ["x"])
    }

    @Test func bootstrapServesCacheThenReconcilesToDB() async throws {
        let container = try makeContainer()
        seed(3, into: container.mainContext)             // DB has a0,a1,a2
        try container.mainContext.save()

        // Pre-seed the cache with a DIFFERENT set so we can tell which path produced `summaries`.
        let cache = tempCache()
        let cachedContext = try makeContainer().mainContext
        insertArticle("cached", into: cachedContext, createdAt: .now)
        try cachedContext.save()   // permanent persistentModelID so the cache encodes
        let cachedSummary = ArticleSummary(
            try #require(cachedContext.fetch(FetchDescriptor<Article>()).first)
        )
        await cache.save([cachedSummary])

        let store = ArticleStore(container: container, cache: cache)
        await store.bootstrap()

        // After bootstrap completes, summaries reflect the authoritative DB (full load), not the cache.
        #expect(store.hasLoaded == true)
        #expect(store.summaries.map(\.identifier) == ["a0", "a1", "a2"])
    }

    @Test func bootstrapUsesAnchorWindowWhenCacheCold() async throws {
        let container = try makeContainer()
        seed(100, into: container.mainContext)
        try container.mainContext.save()

        let store = ArticleStore(
            container: container,
            cache: tempCache(),                          // empty → cold cache
            anchorProvider: { "a50" }
        )
        await store.bootstrap()

        // Window then full load both completed; final state is the full set, ascending.
        #expect(store.hasLoaded == true)
        #expect(store.summaries.count == 100)
        #expect(store.summaries.first?.identifier == "a0")
        #expect(store.summaries.last?.identifier == "a99")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build-for-testing`
Expected: FAIL to compile — `ArticleStore` has no `init(container:cache:...)` / no `bootstrap()`.

- [ ] **Step 3: Rewrite the `ArticleStore` class**

In `Yana/Services/ArticleStore.swift`, replace the entire `ArticleStore` class (the `@MainActor @Observable final class ArticleStore { ... }` block — leave the `ArticleSummaryLoader` actor above it untouched) with:

```swift
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
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStore`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleStore.swift YanaTests/ArticleStoreTests.swift
git commit -m "feat(store): cache-then-full bootstrap with anchor-window cold path"
```

---

### Task 4: Stale-`persistentID` safety net in article resolution

**Files:**
- Create: `Yana/Services/ArticleResolution.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (replace the inline `resolveArticle` closure with a fallback-aware resolver)
- Test: `YanaTests/ArticleResolutionTests.swift`

**Interfaces:**
- Consumes: `ModelContext`, `Article`.
- Produces: `enum ArticleResolution { static func fetchByIdentifier(_ identifier: String, in context: ModelContext) -> Article? }`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleResolutionTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleResolution")
struct ArticleResolutionTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    @Test func findsArticleByIdentifier() async throws {
        let context = try makeContainer().mainContext
        let a = Article(title: "t", identifier: "wanted", url: "u")
        context.insert(a)
        try context.save()

        let found = ArticleResolution.fetchByIdentifier("wanted", in: context)
        #expect(found?.identifier == "wanted")
    }

    @Test func returnsNilForUnknownIdentifier() async throws {
        let context = try makeContainer().mainContext
        let found = ArticleResolution.fetchByIdentifier("missing", in: context)
        #expect(found == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build-for-testing`
Expected: FAIL to compile — `cannot find 'ArticleResolution' in scope`.

- [ ] **Step 3: Create `ArticleResolution`**

Create `Yana/Services/ArticleResolution.swift`:

```swift
import Foundation
import SwiftData

/// One-row lookup of an `Article` by its stable `identifier`. Used as a fallback when a cached
/// `persistentID` no longer resolves (e.g. after a store migration), so the reader never lands on
/// a blank page for a row the disk cache referenced with a now-stale id.
@MainActor
enum ArticleResolution {
    static func fetchByIdentifier(_ identifier: String, in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
```

- [ ] **Step 4: Wire the fallback into `ReaderScreen`**

In `Yana/Reader/ReaderHostView.swift`, find this line (in the `.loaded` case, ~line 146):

```swift
                    resolveArticle: { modelContext.model(for: $0.persistentID) as? Article },
```

Replace it with:

```swift
                    resolveArticle: resolveFullArticle,
```

Then add this method to the `ReaderScreen` struct, immediately after `recomputeFilter()` (it ends at the `}` before `private var starredTag`):

```swift
    /// Resolve a summary to its live `Article`, falling back to an identifier fetch when the
    /// (possibly cache-originated) `persistentID` no longer resolves.
    private func resolveFullArticle(_ summary: ArticleSummary) -> Article? {
        if let article = modelContext.model(for: summary.persistentID) as? Article { return article }
        return ArticleResolution.fetchByIdentifier(summary.identifier, in: modelContext)
    }
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleResolution`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/ArticleResolution.swift Yana/Reader/ReaderHostView.swift YanaTests/ArticleResolutionTests.swift project.yml
git commit -m "feat(reader): identifier fallback when a cached persistentID misses"
```

---

### Task 5: Full build + regression test sweep

**Files:** none (verification only).

- [ ] **Step 1: Regenerate and build the app**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run the entire test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: `** TEST SUCCEEDED **` — all suites pass (`SummaryIndexCache`, `ArticleSummaryLoader.loadWindow`, `ArticleStore`, `ArticleResolution`, plus pre-existing suites unchanged).

- [ ] **Step 3: Commit (only if regeneration changed `project.yml`/pbxproj)**

```bash
git add -A && git commit -m "chore: regenerate project after cold-start cache work" || echo "nothing to commit"
```

---

## Notes for the implementer

- **Why an `actor` for the cache:** it moves `Data(contentsOf:)` / `write(to:)` off the main actor and serializes concurrent `save()` calls from the debounced refresh. `ArticleStore` (main-actor) `await`s it.
- **Why the window is skipped on a warm launch:** the disk cache already provides a full-sized first dataset; running the window too would briefly *shrink* `summaries`. `bootstrap()` therefore picks cache **or** window, then a single full load.
- **Republish handling is already in place:** `ReaderScreen.onChange(of: store.summaries)` runs `recomputeFilter()` + `reanchorToCurrentArticle()`, re-resolving the anchor by `identifier` each republish, so `currentIndex` stays pinned across cache→full / window→full transitions.
- **`#Predicate` capturing locals:** `anchorDate` and `identifier` are captured `let`s — supported by SwiftData's predicate macro.
