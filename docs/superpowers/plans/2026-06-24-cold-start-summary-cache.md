# Cold-Start Summary-Index Cache + Anchor-Centered Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make the reader interactive at the saved anchor on cold start by serving the article index from a disk cache (warm launch) or a small anchor-centered DB window (cold cache), instead of waiting for a full-library off-main fetch.

**Architecture:** `ArticleStore.bootstrap()` publishes `summaries` from `SummaryIndexCache` (disk) when present, else from `ArticleSummaryLoader.loadWindow(...)` (a ~51-article slice centered on the anchor), flips `hasLoaded` immediately, then reconciles to the authoritative full DB load and rewrites the cache. `ArticleSummary.persistentID` is a runtime-only fast-resolve hint (not persisted); `ArticleResolution` resolves a summary to its live `Article` via that id when present, else by a one-row `identifier` fetch.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftData (`@ModelActor`, `FetchDescriptor`, `#Predicate`), Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform: iOS 26.0+ (iPhone and iPad); deploy/build via simulator `iPhone 17`.
- Swift 6 strict concurrency; annotate main-actor types `@MainActor`; cross-actor values must be `Sendable`.
- Tests use Swift Testing (`@Test`, `#expect`) and are `@MainActor`; SwiftData tests use `ModelConfiguration(isStoredInMemoryOnly: true)`.
- **`-only-testing` uses the test TYPE name, not the `@Suite` display string** — e.g. `-only-testing:YanaTests/SummaryIndexCacheTests` (a wrong identifier silently runs 0 tests and reports success).
- `PersistentIdentifier` MUST NOT be encoded/persisted — it traps when round-tripped through `PropertyListEncoder`/`JSONEncoder` and is invalid across launches. `ArticleSummary.persistentID` is therefore a non-persisted optional, `nil` after a cache rehydrate.
- Sources are directory-globbed in `project.yml` (`path: Yana`, `path: YanaTests`); run `xcodegen generate` after adding any new file.
- No new user-facing strings in this work (no `Localizable.xcstrings` changes required).
- Build command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Full test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`

---

### Task 1: Persistable index — runtime-only `persistentID`, `SummaryIndexCache`, `ArticleResolution`

**Files:**
- Modify: `Yana/Models/ArticleSummary.swift` (make `persistentID` an optional runtime-only field; add custom `Codable` that omits it)
- Create: `Yana/Services/SummaryIndexCache.swift`
- Create: `Yana/Services/ArticleResolution.swift`
- Modify: `Yana/Reader/ReaderHostView.swift:149` (route `resolveArticle` through `ArticleResolution`)
- Modify: `Yana/Views/Config/ArticleListView.swift:72-74` (route `article(for:)` through `ArticleResolution`)
- Test: `YanaTests/SummaryIndexCacheTests.swift`, `YanaTests/ArticleResolutionTests.swift`

**Interfaces:**
- Consumes: `ArticleSummary` (existing; `init(_ article: Article)`), `Article`, `ModelContext`.
- Produces:
  - `ArticleSummary.persistentID: PersistentIdentifier?` + custom `Codable` (encodes every field **except** `persistentID`; decode sets it `nil`).
  - `actor SummaryIndexCache`: `static let shared`; `init(fileURL: URL? = nil)` (default `<Caches>/summary-index.plist`); `func load() -> [ArticleSummary]?`; `func save(_ summaries: [ArticleSummary])`.
  - `enum ArticleResolution` (`@MainActor`): `static func resolve(_ summary: ArticleSummary, in context: ModelContext) -> Article?`; `static func fetchByIdentifier(_ identifier: String, in context: ModelContext) -> Article?`.

- [x] **Step 1: Write the failing tests**

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
        try context.save()
        return ArticleSummary(article)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-test-\(UUID().uuidString).plist")
    }

    @Test func roundTripsSummariesWithoutPersistentID() async throws {
        let context = try makeContainer().mainContext
        let summaries = [try makeSummary("a", in: context), try makeSummary("b", in: context)]
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SummaryIndexCache(fileURL: url)
        await cache.save(summaries)
        let loaded = await cache.load()

        #expect(loaded?.map(\.identifier) == ["a", "b"])
        #expect(loaded?.first?.feedName == "Acme")
        #expect(loaded?.first?.persistentID == nil)   // runtime-only; never persisted
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

    @Test func fetchByIdentifierFindsArticle() async throws {
        let context = try makeContainer().mainContext
        context.insert(Article(title: "t", identifier: "wanted", url: "u"))
        try context.save()
        #expect(ArticleResolution.fetchByIdentifier("wanted", in: context)?.identifier == "wanted")
    }

    @Test func fetchByIdentifierReturnsNilForUnknown() async throws {
        let context = try makeContainer().mainContext
        #expect(ArticleResolution.fetchByIdentifier("missing", in: context) == nil)
    }

    @Test func resolveUsesPersistentIDFastPath() async throws {
        let context = try makeContainer().mainContext
        let article = Article(title: "t", identifier: "live", url: "u")
        context.insert(article)
        try context.save()
        let summary = ArticleSummary(article)   // carries a live persistentID
        #expect(ArticleResolution.resolve(summary, in: context)?.identifier == "live")
    }

    @Test func resolveFallsBackToIdentifierWhenPersistentIDNil() async throws {
        let context = try makeContainer().mainContext
        let article = Article(title: "t", identifier: "rehydrated", url: "u")
        context.insert(article)
        try context.save()

        // A cache-rehydrated summary has no persistentID: encode → decode drops it.
        let data = try PropertyListEncoder().encode([ArticleSummary(article)])
        let decoded = try PropertyListDecoder().decode([ArticleSummary].self, from: data)
        let summary = try #require(decoded.first)
        #expect(summary.persistentID == nil)
        #expect(ArticleResolution.resolve(summary, in: context)?.identifier == "rehydrated")
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build-for-testing`
Expected: FAIL to compile — `SummaryIndexCache` / `ArticleResolution` not in scope.

- [x] **Step 3: Make `persistentID` runtime-only + custom `Codable`**

In `Yana/Models/ArticleSummary.swift`, replace the type from its declaration through the end of `init(_ article:)` with:

```swift
struct ArticleSummary: Identifiable, Sendable, Hashable, Codable {
    /// Runtime-only fast-resolve hint. NOT persisted: `PersistentIdentifier` traps when
    /// round-tripped through an external coder and is invalid across launches anyway. `nil` when
    /// the summary was rehydrated from the disk cache; `ArticleResolution` then resolves by
    /// `identifier`.
    let persistentID: PersistentIdentifier?
    let identifier: String
    let title: String
    let feedName: String
    let feedLogoHash: String?
    let author: String
    let date: Date
    let createdAt: Date
    let tagNames: Set<String>
    let isStarred: Bool

    var id: String { identifier }

    init(_ article: Article) {
        persistentID = article.persistentModelID
        identifier = article.identifier
        title = article.title
        feedName = article.feed?.name ?? ""
        feedLogoHash = article.feed?.logoHash
        author = article.author
        date = article.date
        createdAt = article.createdAt
        tagNames = Set(article.tags.map(\.name))
        isStarred = article.isStarred
    }

    // Persist every field EXCEPT the runtime-only `persistentID`.
    private enum CodingKeys: String, CodingKey {
        case identifier, title, feedName, feedLogoHash, author, date, createdAt, tagNames, isStarred
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        persistentID = nil
        identifier = try c.decode(String.self, forKey: .identifier)
        title = try c.decode(String.self, forKey: .title)
        feedName = try c.decode(String.self, forKey: .feedName)
        feedLogoHash = try c.decodeIfPresent(String.self, forKey: .feedLogoHash)
        author = try c.decode(String.self, forKey: .author)
        date = try c.decode(Date.self, forKey: .date)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        tagNames = try c.decode(Set<String>.self, forKey: .tagNames)
        isStarred = try c.decode(Bool.self, forKey: .isStarred)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifier, forKey: .identifier)
        try c.encode(title, forKey: .title)
        try c.encode(feedName, forKey: .feedName)
        try c.encodeIfPresent(feedLogoHash, forKey: .feedLogoHash)
        try c.encode(author, forKey: .author)
        try c.encode(date, forKey: .date)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(tagNames, forKey: .tagNames)
        try c.encode(isStarred, forKey: .isStarred)
    }
}
```

(`Hashable`/`Equatable` stay synthesized over all stored properties, including the optional `persistentID`.)

- [x] **Step 4: Create `SummaryIndexCache`**

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

    /// The cached index, or `nil` when the file is absent or fails to decode. `nil` is a clean
    /// signal to fall back to the DB — never a crash.
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

- [x] **Step 5: Create `ArticleResolution`**

Create `Yana/Services/ArticleResolution.swift`:

```swift
import Foundation
import SwiftData

/// Resolves an `ArticleSummary` to its live `Article`. Fast path: the runtime `persistentID`.
/// Fallback: a one-row `identifier` fetch when that id is absent (cache-rehydrated) or stale
/// (after a store migration) — so the reader never lands on a blank page for a known article.
@MainActor
enum ArticleResolution {
    static func resolve(_ summary: ArticleSummary, in context: ModelContext) -> Article? {
        if let pid = summary.persistentID, let article = context.model(for: pid) as? Article {
            return article
        }
        return fetchByIdentifier(summary.identifier, in: context)
    }

    static func fetchByIdentifier(_ identifier: String, in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
```

- [x] **Step 6: Route both resolve sites through `ArticleResolution`**

In `Yana/Reader/ReaderHostView.swift`, find (≈ line 149, inside the `.loaded` case):

```swift
                    resolveArticle: { modelContext.model(for: $0.persistentID) as? Article },
```

Replace with:

```swift
                    resolveArticle: { ArticleResolution.resolve($0, in: modelContext) },
```

In `Yana/Views/Config/ArticleListView.swift`, replace the body of `article(for:)` (≈ lines 72-74):

```swift
    private func article(for summary: ArticleSummary) -> Article? {
        modelContext.model(for: summary.persistentID) as? Article
    }
```

with:

```swift
    private func article(for summary: ArticleSummary) -> Article? {
        ArticleResolution.resolve(summary, in: modelContext)
    }
```

- [x] **Step 7: Regenerate and run the tests**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SummaryIndexCacheTests -only-testing:YanaTests/ArticleResolutionTests`
Expected: PASS — 3 + 4 = 7 tests, no crash / no "unexpected exit".

- [x] **Step 8: Confirm the pre-existing `ArticleSummary` test still passes**

`YanaTests/ArticleSummaryTests.swift:36` asserts `summary.persistentID == article.persistentModelID`; this still compiles and passes (optional-vs-non-optional `==`). Verify:

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummaryTests`
Expected: PASS.

- [x] **Step 9: Commit**

```bash
git add Yana/Models/ArticleSummary.swift Yana/Services/SummaryIndexCache.swift Yana/Services/ArticleResolution.swift Yana/Reader/ReaderHostView.swift Yana/Views/Config/ArticleListView.swift YanaTests/SummaryIndexCacheTests.swift YanaTests/ArticleResolutionTests.swift project.yml
git commit -m "feat(cache): persistable index + runtime-only persistentID + ArticleResolution"
```

---

### Task 2: Anchor-centered window fetch on `ArticleSummaryLoader`

**Files:**
- Modify: `Yana/Services/ArticleStore.swift` (add `loadWindow` + a private light-descriptor helper to the `ArticleSummaryLoader` actor)
- Test: `YanaTests/ArticleSummaryLoaderTests.swift`

**Interfaces:**
- Consumes: existing `@ModelActor actor ArticleSummaryLoader` with `func load() throws -> [ArticleSummary]`.
- Produces: `func loadWindow(around anchorID: String?, radius: Int) throws -> [ArticleSummary]` — ascending (oldest→new) slice centered on the anchor row (inclusive); when `anchorID` is `nil` or not found, the newest `2*radius + 1` articles ascending.

- [x] **Step 1: Write the failing test**

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
        #expect(window.map(\.identifier) == ["a45","a46","a47","a48","a49","a50","a51","a52","a53","a54","a55"])
    }

    @Test func fallsBackToNewestWhenAnchorMissing() async throws {
        let container = try makeContainer()
        seed(10, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: "does-not-exist", radius: 2)
        #expect(window.map(\.identifier) == ["a5","a6","a7","a8","a9"])   // newest 2*2+1, ascending
    }

    @Test func fallsBackToNewestWhenAnchorNil() async throws {
        let container = try makeContainer()
        seed(4, into: container.mainContext)
        try container.mainContext.save()

        let loader = ArticleSummaryLoader(modelContainer: container)
        let window = try await loader.loadWindow(around: nil, radius: 10)
        #expect(window.map(\.identifier) == ["a0","a1","a2","a3"])   // fewer than window: all, ascending
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build-for-testing`
Expected: FAIL to compile — `ArticleSummaryLoader` has no member `loadWindow`.

- [x] **Step 3: Implement `loadWindow` + helper**

In `Yana/Services/ArticleStore.swift`, inside the `ArticleSummaryLoader` actor (right after the existing `load()` method), add:

```swift
    /// Anchor-centered slice for the cold-cache fast path: the ~`2*radius+1` articles around the
    /// saved anchor (inclusive), ascending. Falls back to the newest `2*radius+1` when there is no
    /// anchor or it is gone. Same light columns / prefetch as `load()`.
    func loadWindow(around anchorID: String?, radius: Int) throws -> [ArticleSummary] {
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

- [x] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummaryLoaderTests`
Expected: PASS (3 tests).

- [x] **Step 5: Commit**

```bash
git add Yana/Services/ArticleStore.swift YanaTests/ArticleSummaryLoaderTests.swift project.yml
git commit -m "feat(store): anchor-centered window fetch on ArticleSummaryLoader"
```

---

### Task 3: `ArticleStore` two-phase bootstrap (cache → full / window → full)

**Files:**
- Modify: `Yana/Services/ArticleStore.swift` (`ArticleStore` class only — leave the `ArticleSummaryLoader` actor above it untouched)
- Test: `YanaTests/ArticleStoreTests.swift` (inject a temp cache; add cache-path and window-path tests)

**Interfaces:**
- Consumes: `SummaryIndexCache` (Task 1), `ArticleSummaryLoader.loadWindow` (Task 2).
- Produces: `ArticleStore.init(container:cache:anchorProvider:)` with defaults `cache: .shared`, `anchorProvider: { AppSettings().timelineAnchorIdentifier }`; `func bootstrap() async`; unchanged public `summaries` / `hasLoaded` / `refreshNow()` / `start()` surface.

- [x] **Step 1: Replace the test file**

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

        // Pre-seed the cache with a DIFFERENT id so we can tell the paths apart.
        let cache = tempCache()
        let cachedContext = try makeContainer().mainContext
        insertArticle("cached", into: cachedContext, createdAt: .now)
        try cachedContext.save()
        let cachedSummary = ArticleSummary(
            try #require(cachedContext.fetch(FetchDescriptor<Article>()).first)
        )
        await cache.save([cachedSummary])

        let store = ArticleStore(container: container, cache: cache)
        await store.bootstrap()

        #expect(store.hasLoaded == true)
        #expect(store.summaries.map(\.identifier) == ["a0", "a1", "a2"])   // reconciled to DB
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

        #expect(store.hasLoaded == true)
        #expect(store.summaries.count == 100)
        #expect(store.summaries.first?.identifier == "a0")
        #expect(store.summaries.last?.identifier == "a99")
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build-for-testing`
Expected: FAIL to compile — `ArticleStore` has no `init(container:cache:...)` / no `bootstrap()`.

- [x] **Step 3: Rewrite the `ArticleStore` class**

In `Yana/Services/ArticleStore.swift`, replace the entire `ArticleStore` class (the `@MainActor @Observable final class ArticleStore { ... }` block — leave the `ArticleSummaryLoader` actor untouched) with:

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

- [x] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleStoreTests`
Expected: PASS (4 tests).

- [x] **Step 5: Commit**

```bash
git add Yana/Services/ArticleStore.swift YanaTests/ArticleStoreTests.swift
git commit -m "feat(store): cache-then-full bootstrap with anchor-window cold path"
```

---

### Task 4: Full build + regression test sweep

**Files:** none (verification only).

- [x] **Step 1: Regenerate and build the app**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 2: Run the entire test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: `** TEST SUCCEEDED **` — all suites pass (`SummaryIndexCache`, `ArticleResolution`, `ArticleSummaryLoader.loadWindow`, `ArticleStore`, plus pre-existing suites), no "unexpected exit".

- [x] **Step 3: Commit (only if regeneration changed project files)**

```bash
git add -A && git commit -m "chore: regenerate project after cold-start cache work" || echo "nothing to commit"
```

---

## Notes for the implementer

- **Why `persistentID` is optional and unencoded:** `PersistentIdentifier` traps when round-tripped through `PropertyListEncoder`/`JSONEncoder` (a cache `save`/`load` of it crashes, not throws). It is a runtime resolution hint only; cache-rehydrated summaries carry `nil` and resolve by `identifier`.
- **Why an `actor` for the cache:** file IO runs off the main actor and concurrent `save()`s serialize.
- **Why the window is skipped on a warm launch:** the disk cache already provides a full-sized first dataset; running the window too would briefly *shrink* `summaries`. `bootstrap()` picks cache **or** window, then one full load.
- **Republish handling already exists:** `ReaderScreen.onChange(of: store.summaries)` runs `recomputeFilter()` + `reanchorToCurrentArticle()`, re-resolving the anchor by `identifier` each republish, so `currentIndex` stays pinned across cache→full / window→full transitions.
- **`#Predicate` capturing locals:** `anchorDate` and `identifier` are captured `let`s — supported by SwiftData's predicate macro.
