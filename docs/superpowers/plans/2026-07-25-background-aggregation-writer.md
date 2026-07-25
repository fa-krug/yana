# Background Aggregation Write Actor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the entire aggregation write path (article upsert, per-feed save, retention cleanup) off the main actor onto a background `@ModelActor`, so runs never stutter the reader — including while inserting articles.

**Architecture:** A new `@ModelActor AggregationWriter` owns its own background `ModelContext` and runs the whole per-feed pipeline (fetch → aggregate → AI → parse → upsert → save → retention) off-main. `AggregationService` stays `@MainActor` but becomes a thin coordinator: it snapshots `Sendable` inputs, calls the writer, and does main-only follow-ups (iCloud pull/push/delete, `lastRunFailures`, `updateProgress`). No `Feed`/`Article`/`ModelContext` crosses the actor boundary — only `Sendable` values and `PersistentIdentifier`s.

**Tech Stack:** Swift 6 strict concurrency, SwiftData, Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform: iOS 26.0+ (iPhone/iPad) and Mac Catalyst. Swift 6 strict concurrency, `@MainActor` throughout the UI layer.
- SwiftData store stays local-only: `ModelConfiguration(..., cloudKitDatabase: .none)`. This change is purely about *which* `ModelContext` performs writes; no SwiftData CloudKit mirroring.
- **Cross-context propagation (verified by spike):** a background context's committed save is visible to the main context ONLY via a **fresh `FetchDescriptor` fetch** (sees inserts + updates) or `context.model(for: id)` (refreshes **scalars** of an existing object, NOT to-many relationship arrays, NOT newly-inserted relationship members). Already-held object references and their `.articles`/`.tags` arrays go **stale**. Every consumer and test assertion that must observe a background write MUST use a fresh fetch or `model(for:)` scalar read — never a held reference's relationship array.
- Public API of `AggregationService` is unchanged: `updateAll()`, `update(feed:)`, `update(article:)`, `forceReload(feed:)`, `forceReload(article:)`, `summarize(_:)`, plus `@Observable` `isUpdating`/`updateProgress`/`lastRunFailures` and statics `userFacingMessage(for:)`/`makeAIConfig(...)`/`defaultLogoResolver`/`parseBlocks(_:)`. Call sites (`FeedsView`, `ReaderScreen`/`ReaderHostView`, Mac `TimelineModel`, `BackgroundRefreshManager`) must not need edits.
- Preserve exactly: per-feed `save()` (durable partial batches), cancellation is not a feed failure, one feed's failure never aborts the run, run cap (`AggregationLogic.runLimit`) + intake window + daily-collected count, bounded concurrency window `maxConcurrentFeedUpdates = 5`, retention only on non-passive devices, `createdAt`/Starred preservation on update.
- All user-facing strings localized (`Localizable.xcstrings`, `en`+`de`) — this change adds none.
- Build/test: `xcodegen generate` then `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`. Filter a Swift Testing suite by its **type name**, e.g. `-only-testing:YanaTests/AggregationServiceTests`.

---

### Task 1: Make `ArticleUpsert.apply` actor-agnostic

Remove the `@MainActor` annotation so the writer can call it from its actor. Nothing inside `apply` requires main isolation — it operates purely on the `context`/`Feed`/closures handed to it. Main-actor callers can still call a `nonisolated` synchronous function unchanged.

**Files:**
- Modify: `Yana/Aggregators/ArticleUpsert.swift:24` (remove `@MainActor` line above `static func apply`)
- Test: `YanaTests/ArticleUpsertTests.swift` (existing; no change expected)

**Interfaces:**
- Produces: `ArticleUpsert.apply(_:to:starredTag:starredIdentifiers:context:now:jitter:blocksFor:canonicalCreatedAt:onUpsert:) -> Int` — now callable from any isolation.

- [ ] **Step 1: Remove the annotation**

In `Yana/Aggregators/ArticleUpsert.swift`, delete the `@MainActor` line so the declaration reads:

```swift
    @discardableResult
    static func apply(
        _ aggregated: [AggregatedArticle],
        to feed: Feed,
        starredTag: Tag?,
        starredIdentifiers: Set<String> = [],
        context: ModelContext,
        now: Date,
        jitter: () -> TimeInterval = { .random(in: 0..<importJitterWindow) },
        blocksFor: (AggregatedArticle) -> [Block] = ArticleUpsert.defaultBlocks,
        canonicalCreatedAt: (String) -> Date? = { _ in nil },
        onUpsert: (String) -> Void = { _ in }
    ) -> Int {
```

- [ ] **Step 2: Regenerate + build the test target**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/ArticleUpsertTests test`
Expected: PASS (compiles; `apply` still works from `@MainActor` tests).

- [ ] **Step 3: Confirm `AggregationService` still compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationServiceTests test`
Expected: PASS (the existing main-actor `upsert`/`forceReload(article:)` callers are unaffected).

- [ ] **Step 4: Commit**

```bash
git add Yana/Aggregators/ArticleUpsert.swift
git commit -m "Make ArticleUpsert.apply actor-agnostic (drop @MainActor)"
```

---

### Task 2: Rewrite aggregation tests to fresh-fetch assertions (safety net)

Convert every assertion that reads a held `Feed` reference's relationship (`feed.articles`) or scalars (`feed.lastError`, `feed.lastFetchedAt`, `feed.logoHash`) to read via a **fresh fetch** (for articles/relationships) or `context.model(for:)` (for feed scalars). This is behavior-preserving on the current main-context implementation — a context sees its own writes via a fresh fetch too — so the suite stays GREEN now and becomes the safety net that verifies the background path in Task 5.

**Files:**
- Modify: `YanaTests/AggregationServiceTests.swift`
- Modify: `YanaTests/AggregationSummarizeTests.swift`

**Interfaces:**
- Produces (test helpers, added at the top of each affected suite):

```swift
    /// Fresh fetch of all articles (sees writes from any sibling context of this container).
    private func allArticles(_ context: ModelContext) -> [Article] {
        (try? context.fetch(FetchDescriptor<Article>())) ?? []
    }
    /// Fresh fetch of a single feed's articles by the feed's identifier (relationship read on
    /// freshly-fetched Article objects is not stale).
    private func articles(_ context: ModelContext, feed identifier: String) -> [Article] {
        allArticles(context).filter { $0.feed?.identifier == identifier }
    }
    /// Re-resolve a feed so scalar reads (lastError/lastFetchedAt/logoHash) are refreshed.
    private func refetch(_ context: ModelContext, feed id: PersistentIdentifier) -> Feed? {
        context.model(for: id) as? Feed
    }
```

- [ ] **Step 1: Add the helpers**

Add the three helpers above into `AggregationServiceTests` (and, where needed, `AggregationSummarizeTests`).

- [ ] **Step 2: Rewrite article-count / identifier assertions**

Replace held-reference relationship reads with fresh fetches. Capture the feed id BEFORE the run where the test currently reads `feed.articles`. Examples (apply the same transform to every occurrence):

```swift
// BEFORE
#expect(enabled.articles.count == 2)
#expect(disabled.articles.isEmpty)
// AFTER
#expect(articles(context, feed: "a").count == 2)
#expect(articles(context, feed: "b").isEmpty)
```

```swift
// BEFORE
#expect(feed.articles.map(\.identifier) == ["fresh"])
// AFTER
#expect(articles(context, feed: "a").map(\.identifier) == ["fresh"])
```

```swift
// BEFORE
#expect(Set(feed.articles.map(\.identifier)) == ["fresh", "old"])
// AFTER
#expect(Set(articles(context, feed: "a").map(\.identifier)) == ["fresh", "old"])
```

For the 12-feed concurrency test, replace `feed.articles.count == i + 1` with `articles(context, feed: "f\(i)").count == i + 1`.

- [ ] **Step 3: Rewrite feed-scalar assertions**

Capture `let feedID = feed.persistentModelID` after inserting/saving, then:

```swift
// BEFORE
#expect(enabled.lastFetchedAt != nil)
#expect(enabled.lastError == nil)
// AFTER
let f = refetch(context, feed: feedID)
#expect(f?.lastFetchedAt != nil)
#expect(f?.lastError == nil)
```

Apply to every `feed.lastError` / `feed.lastFetchedAt` / `feed.logoHash` / `bad.lastError` / `good.lastError` / `reddit.lastError` / `reddit.lastFetchedAt` assertion. `service.lastRunFailures` assertions stay unchanged (they read the service, not a model).

- [ ] **Step 4: Rewrite article-property assertions (force-reload / summarize)**

For tests that read a held `article`'s refreshed content (`article.plainText`, `article.summary`, `article.createdAt`, `article.isStarred`), capture `let articleID = article.persistentModelID` before the run and re-resolve after:

```swift
// BEFORE
#expect(article.plainText == "REFRESHED")
#expect(article.summary == "")
// AFTER
let a = context.model(for: articleID) as? Article
#expect(a?.plainText == "REFRESHED")
#expect(a?.summary == "")
```

(`model(for:)` refreshes the scalar body fields per the spike.) Apply to `forceReloadArticle*`, `forceReloadDoesNotRetentionCleanupRefreshedArticles`, and the summarize tests. For `forceReloadArticleRefreshesContentPreservingIdentity`, also re-resolve for `createdAt`/`isStarred`. For "article untouched" assertions (`article.plainText.isEmpty`), re-resolve the same way.

- [ ] **Step 5: Run the full affected suites against the CURRENT implementation**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationServiceTests -only-testing:YanaTests/AggregationSummarizeTests test`
Expected: PASS — proves the rewritten assertions hold on the current main-context code (safety net established).

- [ ] **Step 6: Commit**

```bash
git add YanaTests/AggregationServiceTests.swift YanaTests/AggregationSummarizeTests.swift
git commit -m "Rewrite aggregation tests to fresh-fetch assertions (cross-context safety net)"
```

---

### Task 3: Add `canonicalCreatedAtSnapshot()` to `ArticleSyncService`

Expose a `Sendable` copy of the canonical-`createdAt` map so the coordinator can snapshot it (after `pull()`) and pass it into the writer, instead of the writer reaching back to the `@MainActor` service per-article.

**Files:**
- Modify: `Yana/Services/ArticleSync/ArticleSyncService.swift` (near line 97)
- Test: `YanaTests/ArticleSync/` (add a small test file `ArticleSyncCanonicalSnapshotTests.swift`)

**Interfaces:**
- Produces: `@MainActor func canonicalCreatedAtSnapshot() -> [String: Date]` on `ArticleSyncService`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleSync/ArticleSyncCanonicalSnapshotTests.swift`. Match the construction pattern used by the existing `ArticleSync` tests (open `YanaTests/ArticleSync/` and reuse its fake `ArticleZoneStore` + init helper). Skeleton:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSyncCanonicalSnapshot")
struct ArticleSyncCanonicalSnapshotTests {
    @Test func snapshotReturnsCanonicalCreatedAtByUID() async {
        // Arrange a service whose canonical map has been populated by a pull().
        // (Reuse the existing ArticleSync test harness to build the service + fake store
        //  seeded with one SyncedArticle record whose uid = "u1", createdAt = fixedDate.)
        let fixed = Date(timeIntervalSince1970: 1_000)
        let service = /* build via existing harness, seed record uid:"u1" createdAt:fixed */
        await service.pull()

        let snap = service.canonicalCreatedAtSnapshot()

        #expect(snap["u1"] == fixed)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/ArticleSyncCanonicalSnapshotTests test`
Expected: FAIL — `canonicalCreatedAtSnapshot` does not exist (compile error).

- [ ] **Step 3: Implement the accessor**

In `ArticleSyncService.swift`, directly below `func canonicalCreatedAt(forUID:)` (line 97):

```swift
    /// A `Sendable` copy of the canonical-`createdAt` map for handing to the background writer.
    /// Snapshot AFTER `pull()` so newly-reconciled UIDs are included.
    func canonicalCreatedAtSnapshot() -> [String: Date] { canonicalCreatedAtByUID }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/ArticleSyncCanonicalSnapshotTests test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleSync/ArticleSyncService.swift YanaTests/ArticleSync/ArticleSyncCanonicalSnapshotTests.swift
git commit -m "Expose canonicalCreatedAtSnapshot() for the background writer"
```

---

### Task 4: Create the `AggregationWriter` background actor

The `@ModelActor` that runs the whole pipeline off-main in its own context. It is a faithful move of `AggregationService.aggregate(feed:)` / `updateAll` / `forceReload*` / `summarize` logic, with `context` → `modelContext` and all main-actor dependencies replaced by the `Sendable` values carried in `RunInputs`. Progress is emitted via a `Sendable` callback; results are returned as a `Sendable RunResult`.

**Files:**
- Create: `Yana/Services/AggregationWriter.swift`
- Test: `YanaTests/AggregationWriterTests.swift`

**Interfaces:**
- Consumes: `ArticleUpsert.apply(...)` (Task 1), `AggregatorFactory` (`@Sendable (FeedConfig, AggregatorCredentials) -> (any Aggregator)?`), `AIProcessing` (`Sendable`), `AggregationService.LogoResolver` (`@Sendable (FeedConfig, any Aggregator) async -> String?`), `AggregationService.FeedFailure` (`Sendable`), `AggregationLogic`, `RetentionCleanup.run(context:retentionDays:now:) -> [String]`, `ArticleUID.make(for:)`, `AggregatorCredentials` (`Sendable`).
- Produces:

```swift
enum AggregationProgress: Sendable { case start(total: Int); case advance }

struct AggregationRunInputs: Sendable {
    let makeAggregator: AggregatorFactory
    let processor: any AIProcessing
    let logoResolver: AggregationService.LogoResolver
    let credentials: AggregatorCredentials
    let now: Date
    /// Per-feed starred article identifiers (captures a `Set<StarredMark>` snapshot).
    let starredIdentifiers: @Sendable (_ feedIdentifier: String, _ aggregatorType: String) -> Set<String>
    let canonicalCreatedAt: [String: Date]
    let isSourceEnabled: @Sendable (AggregatorType) -> Bool
    let retentionDays: Int
    let isPassiveDevice: Bool
    let progress: @Sendable (AggregationProgress) -> Void
}

struct AggregationRunResult: Sendable {
    var inserted: Int = 0
    var failures: [AggregationService.FeedFailure] = []
    var touchedUIDs: Set<String> = []
    var deletedUIDs: [String] = []
}

@ModelActor
actor AggregationWriter {
    func runUpdateAll(_ inputs: AggregationRunInputs) async -> AggregationRunResult
    func runUpdate(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult
    func runForceReloadFeed(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult
    func runForceReloadArticle(articleID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult
    /// Returns (didSummarize, touchedUID?) — coordinator pushes the uid when true.
    func runSummarize(articleID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> (Bool, String?)
}
```

- [ ] **Step 1: Write failing tests**

Create `YanaTests/AggregationWriterTests.swift`. Build inputs with fakes (reuse the `FakeAggregator`/`FakeAIProcessor` shapes from `AggregationServiceTests`, redeclared locally or lifted to a shared helper). Assert via **fresh fetch** on a main context sharing the writer's container.

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationWriter")
struct AggregationWriterTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let seed = ModelContext(container)
        seed.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        try seed.save()
        return container
    }

    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }
    private struct IdentityAI: AIProcessing {
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] { input }
    }
    private func inputs(
        makeAggregator: @escaping AggregatorFactory,
        progress: @escaping @Sendable (AggregationProgress) -> Void = { _ in }
    ) -> AggregationRunInputs {
        AggregationRunInputs(
            makeAggregator: makeAggregator, processor: IdentityAI(),
            logoResolver: { _, _ in nil }, credentials: .resolved(), now: .now,
            starredIdentifiers: { _, _ in [] }, canonicalCreatedAt: [:],
            isSourceEnabled: { _ in true }, retentionDays: 30, isPassiveDevice: false,
            progress: progress)
    }
    private func aggregated(_ id: String, date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: id, identifier: id, url: id, rawContent: "", content: "c", date: date, author: "", iconURL: nil)
    }

    @Test func runUpdateAllInsertsOffOwnContextVisibleViaFreshFetch() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed); try main.save()

        let writer = AggregationWriter(modelContainer: container)
        let result = await writer.runUpdateAll(inputs { _, _ in
            FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
        })

        #expect(result.inserted == 2)
        #expect(result.touchedUIDs.count == 2)
        // Fresh fetch on the main context sees the background inserts.
        #expect((try main.fetch(FetchDescriptor<Article>())).count == 2)
    }

    @Test func runUpdateAllEmitsProgressStartThenAdvances() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        for i in 0..<3 { main.insert(Feed(name: "F\(i)", aggregatorType: .feedContent, identifier: "f\(i)")) }
        try main.save()

        final class Rec: @unchecked Sendable { var started = -1; var advances = 0 }
        let rec = Rec()
        let writer = AggregationWriter(modelContainer: container)
        _ = await writer.runUpdateAll(inputs(makeAggregator: { _, _ in FakeAggregator(articles: []) }) { ev in
            switch ev { case .start(let t): rec.started = t; case .advance: rec.advances += 1 }
        })

        #expect(rec.started == 3)
        #expect(rec.advances == 3)
    }

    @Test func runUpdateSkipsDisabledSourceWithoutError() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
        main.insert(reddit); try main.save()
        let feedID = reddit.persistentModelID

        let writer = AggregationWriter(modelContainer: container)
        var ins = inputs { _, _ in FakeAggregator(articles: [self.aggregated("x")]) }
        ins = AggregationRunInputs(
            makeAggregator: ins.makeAggregator, processor: ins.processor, logoResolver: ins.logoResolver,
            credentials: ins.credentials, now: ins.now, starredIdentifiers: ins.starredIdentifiers,
            canonicalCreatedAt: ins.canonicalCreatedAt, isSourceEnabled: { $0 != .reddit },
            retentionDays: ins.retentionDays, isPassiveDevice: ins.isPassiveDevice, progress: ins.progress)
        let result = await writer.runUpdate(feedID: feedID, ins)

        #expect(result.inserted == 0)
        #expect((try main.fetch(FetchDescriptor<Article>())).isEmpty)
    }

    @Test func retentionDeletesAgedOutAndReportsDeletedUIDs() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed)
        let old = Article(title: "old", identifier: "old", url: "u", date: .now, author: "", iconURL: nil)
        old.feed = feed
        old.createdAt = Date.now.addingTimeInterval(-40 * 24 * 3600)   // beyond 30-day retention
        main.insert(old); try main.save()

        let writer = AggregationWriter(modelContainer: container)
        let result = await writer.runUpdateAll(inputs { _, _ in FakeAggregator(articles: [self.aggregated("fresh")]) })

        let ids = Set((try main.fetch(FetchDescriptor<Article>())).map(\.identifier))
        #expect(ids == ["fresh"])                      // aged-out removed, new kept
        #expect(!result.deletedUIDs.isEmpty)           // reported for remote tombstoning
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationWriterTests test`
Expected: FAIL — `AggregationWriter`/`AggregationRunInputs`/`AggregationRunResult` undefined.

- [ ] **Step 3: Implement `AggregationWriter.swift`**

Create `Yana/Services/AggregationWriter.swift` with the types from the Interfaces block plus the implementation. The pipeline is the move of `AggregationService.aggregate(feed:)` with the noted substitutions. Full implementation:

```swift
import Foundation
import SwiftData

enum AggregationProgress: Sendable { case start(total: Int); case advance }

struct AggregationRunInputs: Sendable {
    let makeAggregator: AggregatorFactory
    let processor: any AIProcessing
    let logoResolver: AggregationService.LogoResolver
    let credentials: AggregatorCredentials
    let now: Date
    let starredIdentifiers: @Sendable (_ feedIdentifier: String, _ aggregatorType: String) -> Set<String>
    let canonicalCreatedAt: [String: Date]
    let isSourceEnabled: @Sendable (AggregatorType) -> Bool
    let retentionDays: Int
    let isPassiveDevice: Bool
    let progress: @Sendable (AggregationProgress) -> Void
}

struct AggregationRunResult: Sendable {
    var inserted: Int = 0
    var failures: [AggregationService.FeedFailure] = []
    var touchedUIDs: Set<String> = []
    var deletedUIDs: [String] = []
}

/// Runs the aggregation write path off the main actor in its own `ModelContext`. Everything the
/// old `AggregationService.aggregate(feed:)` did on the main context happens here instead; only
/// `Sendable` values cross the boundary (see `AggregationRunInputs`/`AggregationRunResult`).
@ModelActor
actor AggregationWriter {
    private static let maxConcurrentFeedUpdates = 5
    private struct CapReached: Error {}

    // MARK: Public run entry points

    func runUpdateAll(_ inputs: AggregationRunInputs) async -> AggregationRunResult {
        var result = AggregationRunResult()
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { inputs.isSourceEnabled($0.type) }
        try? modelContext.save()   // permanent ids before we carry them across the task group
        let ids = feeds.map(\.persistentModelID)
        inputs.progress(.start(total: ids.count))

        await withTaskGroup(of: (Int, [FeedFailureBox]).self) { group in
            var next = 0
            let window = min(Self.maxConcurrentFeedUpdates, ids.count)
            while next < window { let id = ids[next]; group.addTask { await self.aggregateBoxed(feedID: id, inputs) }; next += 1 }
            while let (ins, fails) = await group.next() {
                inputs.progress(.advance)
                result.inserted += ins
                result.failures.append(contentsOf: fails.map(\.failure))
                for b in fails { result.touchedUIDs.formUnion(b.touched) }
                if Task.isCancelled { break }
                if next < ids.count { let id = ids[next]; group.addTask { await self.aggregateBoxed(feedID: id, inputs) }; next += 1 }
            }
        }
        // Accumulated touched uids come back through the boxes; also gather from the shared accumulator.
        result.touchedUIDs.formUnion(pendingTouched)
        pendingTouched.removeAll()
        result.deletedUIDs = cleanup(inputs)
        return result
    }

    func runUpdate(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult {
        var result = AggregationRunResult()
        guard let feed = modelContext.model(for: feedID) as? Feed,
              inputs.isSourceEnabled(feed.type) else { return result }
        result.inserted = await aggregate(feed: feed, force: false, inputs: inputs, failures: &result.failures)
        result.touchedUIDs.formUnion(pendingTouched); pendingTouched.removeAll()
        result.deletedUIDs = cleanup(inputs)
        return result
    }

    func runForceReloadFeed(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult {
        var result = AggregationRunResult()
        guard let feed = modelContext.model(for: feedID) as? Feed,
              inputs.isSourceEnabled(feed.type) else { return result }
        result.inserted = await aggregate(feed: feed, force: true, inputs: inputs, failures: &result.failures)
        try? modelContext.save()
        result.touchedUIDs.formUnion(pendingTouched); pendingTouched.removeAll()
        return result   // forceReload does NOT run retention (matches current behavior)
    }

    func runForceReloadArticle(articleID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult {
        var result = AggregationRunResult()
        guard let article = modelContext.model(for: articleID) as? Article, let feed = article.feed else { return result }
        let config = FeedConfig(feed: feed, collectedToday: 0)
        guard let aggregator = inputs.makeAggregator(config, inputs.credentials) else { return result }
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: "", content: "", date: article.date, author: article.author, iconURL: article.iconURL)
        let refreshed: AggregatedArticle?
        do { refreshed = try await aggregator.refetch(seed) }
        catch { if Task.isCancelled { return result }; refreshed = nil }
        guard let refreshed else { return result }
        let processed = await inputs.processor.process([refreshed], ai: config.options.ai)
        result.inserted = ArticleUpsert.apply(
            processed, to: feed, starredTag: starredTag(),
            starredIdentifiers: inputs.starredIdentifiers(feed.identifier, feed.aggregatorType),
            context: modelContext, now: inputs.now,
            canonicalCreatedAt: { inputs.canonicalCreatedAt[$0] },
            onUpsert: { self.pendingTouched.insert($0) })
        try? modelContext.save()
        result.touchedUIDs.formUnion(pendingTouched); pendingTouched.removeAll()
        return result
    }

    func runSummarize(articleID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> (Bool, String?) {
        guard let article = modelContext.model(for: articleID) as? Article else { return (false, nil) }
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: "", content: article.plainText, date: article.date, author: article.author, iconURL: article.iconURL)
        let processed = await inputs.processor.process([seed], ai: AIOptions(summarize: true))
        guard let summary = processed.first?.summary, !summary.isEmpty else { return (false, nil) }
        article.summary = summary
        try? modelContext.save()
        return (true, ArticleUID.make(for: article))
    }

    // MARK: Internals

    /// Touched uids accumulated across the current run's upserts (actor-isolated state).
    private var pendingTouched: Set<String> = []

    private struct FeedFailureBox: Sendable {
        let failure: AggregationService.FeedFailure?
        let touched: Set<String>
    }

    /// Task-group adapter: runs one feed and returns its inserted count + any failure + touched uids,
    /// so the concurrent path collects everything without racing on `pendingTouched`.
    private func aggregateBoxed(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> (Int, [FeedFailureBox]) {
        guard let feed = modelContext.model(for: feedID) as? Feed else { return (0, []) }
        var failures: [AggregationService.FeedFailure] = []
        let before = pendingTouched
        let inserted = await aggregate(feed: feed, force: false, inputs: inputs, failures: &failures)
        let touched = pendingTouched.subtracting(before)
        return (inserted, failures.map { FeedFailureBox(failure: $0, touched: touched) }
                    + (failures.isEmpty ? [FeedFailureBox(failure: nil, touched: touched)] : []))
    }

    /// Faithful move of the old `AggregationService.aggregate(feed:force:)`.
    private func aggregate(feed: Feed, force: Bool, inputs: AggregationRunInputs, failures: inout [AggregationService.FeedFailure]) async -> Int {
        let runNow = inputs.now
        let collected = collectedToday(for: feed, now: runNow)
        let config = FeedConfig(feed: feed, collectedToday: collected, force: force)
        guard let aggregator = inputs.makeAggregator(config, inputs.credentials) else {
            let message = AggregatorError.notImplemented(feed.type).errorDescription ?? ""
            feed.lastError = message
            failures.append(.init(feedName: feed.name, message: message))
            return 0
        }
        let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
        let feedID = feed.persistentModelID
        var inserted = 0, kept = 0
        do {
            try aggregator.validate()
            do {
                try await aggregator.aggregate { article in
                    guard kept < cap else { throw CapReached() }
                    guard force || AggregationLogic.isWithinIntakeWindow(article.date, now: runNow) else { return }
                    let processed = await inputs.processor.process([article], ai: config.options.ai)
                    let blocks = await AggregationService.parseBlocks(processed)
                    inserted += self.upsert(processed, blocks: blocks, feedID: feedID, now: runNow, inputs: inputs)
                    kept += 1
                }
            } catch is CapReached {}
            feed.lastFetchedAt = runNow
            feed.lastError = nil
            if feed.logoHash == nil, let hash = await inputs.logoResolver(config, aggregator) { feed.logoHash = hash }
            try? modelContext.save()
            return inserted
        } catch {
            if Task.isCancelled || error.isCancellationError { try? modelContext.save(); return inserted }
            let message = AggregationService.userFacingMessage(for: error)
            feed.lastError = message
            failures.append(.init(feedName: feed.name, message: message))
            try? modelContext.save()
            return inserted
        }
    }

    private func upsert(_ processed: [AggregatedArticle], blocks: [String: [Block]], feedID: PersistentIdentifier, now: Date, inputs: AggregationRunInputs) -> Int {
        guard let feed = modelContext.model(for: feedID) as? Feed else { return 0 }
        return ArticleUpsert.apply(
            processed, to: feed, starredTag: starredTag(),
            starredIdentifiers: inputs.starredIdentifiers(feed.identifier, feed.aggregatorType),
            context: modelContext, now: now,
            blocksFor: { blocks[$0.identifier] ?? ArticleUpsert.defaultBlocks(for: $0) },
            canonicalCreatedAt: { inputs.canonicalCreatedAt[$0] },
            onUpsert: { self.pendingTouched.insert($0) })
    }

    private func cleanup(_ inputs: AggregationRunInputs) -> [String] {
        guard !inputs.isPassiveDevice else { return [] }
        let deleted = RetentionCleanup.run(context: modelContext, retentionDays: inputs.retentionDays, now: inputs.now)
        try? modelContext.save()
        return deleted
    }

    private func collectedToday(for feed: Feed, now: Date) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let feedID = feed.persistentModelID
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.feed?.persistentModelID == feedID && $0.createdAt >= startOfDay })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func starredTag() -> Tag? {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        return (try? modelContext.fetch(descriptor))?.first
    }
}
```

Note on `aggregateBoxed`: it returns per-feed touched uids to avoid the task-group children racing on shared state; simplify to a single accumulator if the reviewer prefers, but keep the result deterministic. Verify `error.isCancellationError` and `AggregationService.parseBlocks` are accessible (both currently exist; `parseBlocks` is `nonisolated static`, so it is callable from the actor).

- [ ] **Step 4: Run the writer tests**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationWriterTests test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationWriter.swift YanaTests/AggregationWriterTests.swift
git commit -m "Add AggregationWriter: off-main @ModelActor write pipeline"
```

---

### Task 5: Rewire `AggregationService` into a coordinator over the writer

Replace the service's on-main pipeline with delegation to `AggregationWriter`. Keep the public API + `@Observable` state. Snapshot the main-actor inputs; wrap progress to hop to `@MainActor`; do the iCloud follow-ups. The Task 2 suite (now fresh-fetch based) is the acceptance gate.

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Test: `YanaTests/AggregationServiceTests.swift`, `YanaTests/AggregationSummarizeTests.swift` (unchanged from Task 2; used as the gate)

**Interfaces:**
- Consumes: `AggregationWriter(modelContainer:)`, `AggregationRunInputs`, `AggregationRunResult`, `ArticleSyncService.canonicalCreatedAtSnapshot()` (Task 3), `StarredRegistry.identifiers(forFeedIdentifier:aggregatorType:)`.
- Produces: unchanged public API.

- [ ] **Step 1: Build the input-snapshot helper**

Add to `AggregationService` a private factory that captures the main-actor state as `Sendable` values. `StarredRegistry` is `@MainActor`; capture its per-feed lookup as a `@Sendable` closure over a snapshot. Since `StarredRegistry.identifiers(...)` reads its `marks`, snapshot per-feed lazily is unsafe off-main — instead snapshot the whole set once via a `@Sendable` closure that calls a captured pure function. Simplest correct form: precompute nothing, capture a `@Sendable` closure that reads an immutable `Set<StarredMark>` copy:

```swift
    /// Snapshot all main-actor inputs the writer needs, as Sendable values.
    private func makeRunInputs() -> AggregationRunInputs {
        let settings = AppSettings()
        let marks = starredRegistry.snapshotMarks()   // add this Sendable accessor (see Step 2)
        let canonical = articleSync.canonicalCreatedAtSnapshot()
        return AggregationRunInputs(
            makeAggregator: makeAggregator,
            processor: currentAIProcessor(),
            logoResolver: logoResolver,
            credentials: AggregatorCredentials.resolved(),
            now: now(),
            starredIdentifiers: { feedIdentifier, aggregatorType in
                Set(marks.compactMap { $0.feedIdentifier == feedIdentifier && $0.aggregatorType == aggregatorType ? $0.articleIdentifier : nil })
            },
            canonicalCreatedAt: canonical,
            isSourceEnabled: { [settings] type in settings.isSourceEnabled(type) },
            retentionDays: settings.retentionDays,
            isPassiveDevice: settings.isPassiveDevice,
            progress: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .start(let total): self.updateProgress.start(total: total)
                    case .advance: self.updateProgress.advance()
                    }
                }
            })
    }
```

Confirm `AppSettings.isSourceEnabled` and `settings` are safe to capture in a `@Sendable` closure; if `AppSettings` is not `Sendable`, precompute a `Set<AggregatorType>` of enabled sources on main and capture that instead:

```swift
            let enabledSources = Set(AggregatorType.allCases.filter { settings.isSourceEnabled($0) })
            // ... isSourceEnabled: { enabledSources.contains($0) },
```

Use whichever compiles under Swift 6 strict concurrency; prefer the precomputed `Set` if `AppSettings` capture warns.

- [ ] **Step 2: Add `StarredRegistry.snapshotMarks()`**

In `Yana/Services/StarredRegistry.swift`, add:

```swift
    /// A Sendable copy of the current marks, for handing to the background writer.
    func snapshotMarks() -> Set<StarredMark> { marks }
```

(`StarredMark` is `Codable, Hashable, Sendable`.)

- [ ] **Step 3: Rewrite the public methods to delegate**

Replace the bodies of `updateAll`, `update(feed:)`, `forceReload(feed:)`, `forceReload(article:)`, `summarize(_:)` to snapshot → flush → call the writer → apply results. Keep `update(article:)` delegating to `update(feed:)`. Delete the now-dead private `aggregate(...)`/`upsert(...)`/`save()`/`cleanupAndSave()`/`collectedToday`/`starredTag`/`pendingPushUIDs`/`pushRecentlyChanged`/subscript from the service (they moved into the writer). KEEP `userFacingMessage(for:)`, `makeAIConfig(...)`, `currentAIProcessor()`, `defaultLogoResolver`, `parseBlocks(_:)`, `FeedFailure`, `LogoResolver`. New bodies:

```swift
    @discardableResult
    func updateAll() async -> Int {
        lastRunFailures = []; isUpdating = true
        defer { isUpdating = false; updateProgress.reset() }
        await articleSync.pull()
        try? context.save()                         // flush so the writer's fetch sees pending feeds
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runUpdateAll(makeRunInputs())
        lastRunFailures = result.failures
        await articleSync.push(uids: Array(result.touchedUIDs))
        if !result.deletedUIDs.isEmpty { await articleSync.deleteRemote(uids: result.deletedUIDs) }
        return result.inserted
    }

    @discardableResult
    func update(feed: Feed) async -> Int {
        guard settings.isSourceEnabled(feed.type) else { return 0 }
        lastRunFailures = []; isUpdating = true
        defer { isUpdating = false }
        await articleSync.pull()
        try? context.save()
        let feedID = feed.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runUpdate(feedID: feedID, makeRunInputs())
        lastRunFailures = result.failures
        await articleSync.push(uids: Array(result.touchedUIDs))
        if !result.deletedUIDs.isEmpty { await articleSync.deleteRemote(uids: result.deletedUIDs) }
        return result.inserted
    }

    @discardableResult
    func forceReload(feed: Feed) async -> Int {
        guard settings.isSourceEnabled(feed.type) else { return 0 }
        lastRunFailures = []; isUpdating = true
        defer { isUpdating = false }
        try? context.save()
        let feedID = feed.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runForceReloadFeed(feedID: feedID, makeRunInputs())
        lastRunFailures = result.failures
        await articleSync.push(uids: Array(result.touchedUIDs))
        return result.inserted
    }

    @discardableResult
    func update(article: Article) async -> Int {
        guard let feed = article.feed else { return 0 }
        return await update(feed: feed)
    }

    @discardableResult
    func forceReload(article: Article) async -> Int {
        guard article.feed != nil else { return 0 }
        lastRunFailures = []; isUpdating = true
        defer { isUpdating = false }
        try? context.save()
        let articleID = article.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runForceReloadArticle(articleID: articleID, makeRunInputs())
        await articleSync.push(uids: Array(result.touchedUIDs))
        return result.inserted
    }

    @discardableResult
    func summarize(_ article: Article) async -> Bool {
        try? context.save()
        let articleID = article.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let (ok, uid) = await writer.runSummarize(articleID: articleID, makeRunInputs())
        if let uid { await articleSync.push(uids: [uid]) }
        return ok
    }
```

Keep the stored deps used by `makeRunInputs()` (`context`, `makeAggregator`, `injectedAIProcessor`/`currentAIProcessor`, `now`, `logoResolver`, `settings`, `starredRegistry`, `articleSync`). Remove `pendingPushUIDs`.

- [ ] **Step 4: Run the acceptance gate (Task 2 suites, now over the background path)**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/AggregationServiceTests -only-testing:YanaTests/AggregationSummarizeTests -only-testing:YanaTests/AggregationWriterTests test`
Expected: PASS. If a test that inserts a feed without saving fails to import, confirm the `try? context.save()` flush is present in that method (permanent ids are required before the writer resolves them).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/AggregationService.swift Yana/Services/StarredRegistry.swift
git commit -m "Rewire AggregationService as a coordinator over AggregationWriter"
```

---

### Task 6: Reader staleness — prove updated bodies are visible

The reader resolves via `ArticleResolution.resolve(_:in:)` (main context: `model(for:)` fast-path, then `fetchByIdentifier`). The spike confirms `model(for:)` refreshes scalar body fields (`blockData`/`plainText`/`summary`) after a background update, and a fresh identifier fetch always sees inserts. Add a regression test that writes via a background context and asserts the main context resolves fresh content; only change `ArticleResolution` if the test fails.

**Files:**
- Test: `YanaTests/ArticleResolutionTests.swift` (add cases)
- Modify (only if the test fails): `Yana/Services/ArticleResolution.swift`

**Interfaces:**
- Consumes: `AggregationWriter`, `ArticleResolution.resolve(_:in:)`, `ArticleSummary`.

- [ ] **Step 1: Write the regression test**

Add to `ArticleResolutionTests.swift` (match its existing container/summary construction helpers):

```swift
    @Test func resolveSeesBackgroundUpdatedBody() async throws {
        let container = try makeContainer()   // reuse existing helper
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed)
        let article = Article(title: "OLD", identifier: "id1", url: "u", date: .now, author: "", iconURL: nil)
        article.feed = feed
        article.blocks = BlockParser.blocks(fromHTML: "<p>old</p>", baseURL: nil)
        main.insert(article); try main.save()
        let summary = ArticleSummary(article)

        // Background update via the writer's forceReloadArticle path (EchoRefetch-style fake).
        // Simpler: update directly through a sibling @ModelActor is out of scope; instead update
        // the scalar via a fresh sibling context to mirror the writer, then assert resolution.
        let sibling = ModelContext(container)
        if let a = sibling.model(for: article.persistentModelID) as? Article {
            a.blocks = BlockParser.blocks(fromHTML: "<p>new body</p>", baseURL: nil)
            try sibling.save()
        }

        let resolved = ArticleResolution.resolve(summary, in: main)
        #expect(resolved?.plainText.contains("new body") == true)
    }
```

- [ ] **Step 2: Run it**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:YanaTests/ArticleResolutionTests test`
Expected: PASS (per the spike, `model(for:)` refreshes scalars). If it FAILS, apply Step 3.

- [ ] **Step 3 (conditional): Make resolution refresh-safe**

Only if Step 2 failed: in `ArticleResolution.resolve`, drop the possibly-stale `model(for:)` fast path in favor of the always-fresh identifier fetch when a `persistentID` object's body looks stale — simplest robust form is to prefer `fetchByIdentifier` (a fresh fetch):

```swift
    static func resolve(_ summary: ArticleSummary, in context: ModelContext) -> Article? {
        // Fresh identifier fetch first — a background-committed body update is only guaranteed
        // visible via a fetch, not a held/cached object. Falls back to the pid fast path.
        if let article = fetchByIdentifier(summary.identifier, in: context) { return article }
        if let pid = summary.persistentID, let article = context.model(for: pid) as? Article { return article }
        return nil
    }
```

Re-run Step 2 to confirm PASS.

- [ ] **Step 4: Commit**

```bash
git add YanaTests/ArticleResolutionTests.swift Yana/Services/ArticleResolution.swift
git commit -m "Verify reader resolves background-updated article bodies"
```

---

### Task 7: Full suite, docs, and off-main assertion

**Files:**
- Test: `YanaTests/AggregationWriterTests.swift` (add off-main assertion)
- Modify: `CLAUDE.md` (Architecture › Services description of `AggregationService`)

**Interfaces:** none new.

- [ ] **Step 1: Add an off-main-context assertion to the writer suite**

```swift
    @Test func writerUsesADistinctContextFromMain() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let writer = AggregationWriter(modelContainer: container)
        // The writer's context is created by @ModelActor and is not the main context.
        let sameAsMain = await writer.assertContextIsNot(main)   // add a tiny test-only accessor
        #expect(sameAsMain == false)
    }
```

Add to `AggregationWriter` a minimal accessor guarded for tests:

```swift
    #if DEBUG
    func assertContextIsNot(_ other: ModelContext) -> Bool { modelContext === other }
    #endif
```

- [ ] **Step 2: Run the entire test suite**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -30`
Expected: all suites PASS (Swift Testing reports its total; the single XCTest UI test may show "Executed 1 test"). If the runner fails to launch with a Mach/-308 error, shut down simulators and retry — it is a flake, not a failure.

- [ ] **Step 3: Update CLAUDE.md**

In the Services bullet, update the `AggregationService` description to note it is now a `@MainActor` coordinator that delegates the write path to the `@ModelActor AggregationWriter` (own background `ModelContext`), so upserts/saves/retention run off the main thread; the reader/`ArticleStore` observe committed changes via fresh fetches (the `ModelContext.didSave` observer still fires for the background context's saves). One or two sentences, matching the file's dense style.

- [ ] **Step 4: Commit**

```bash
git add YanaTests/AggregationWriterTests.swift Yana/Services/AggregationWriter.swift CLAUDE.md
git commit -m "Assert writer runs off-main; document background aggregation writer"
```

---

## Self-Review

**Spec coverage:**
- §1 component split → Tasks 4 (writer) + 5 (coordinator). ✅
- §2 Sendable boundary (request/result/progress, `ArticleUpsert` de-isolation, snapshots) → Tasks 1, 3, 4, 5. ✅
- §3 staleness (single-writer, refresh-safe resolution, integration test) → spike (done), Tasks 4/5 tests assert via fresh fetch, Task 6 reader test. ✅
- §4 error/cancellation/durability/concurrency window → preserved verbatim in the moved `aggregate` (Task 4). ✅
- §5 testing (reuse public-API tests, cross-context test, off-main assertion, progress test) → Tasks 2, 4, 6, 7. ✅ (Correction vs. spec: existing tests are *rewritten to fresh-fetch*, not reused verbatim — cross-context propagation makes held-reference reads stale.)

**Placeholder scan:** No "TBD"/"handle errors"/"similar to". The one conditional (Task 6 Step 3) is gated on an explicit test outcome with full code for both branches. The `ArticleSync` test harness reuse (Task 3 Step 1) references the existing `YanaTests/ArticleSync/` fakes rather than inlining them — the implementer opens that folder for the exact initializer; acceptable because that harness already exists and must be matched, not invented.

**Type consistency:** `AggregationRunInputs`/`AggregationRunResult`/`AggregationProgress` field and case names are identical across Tasks 4 and 5. `runUpdateAll`/`runUpdate`/`runForceReloadFeed`/`runForceReloadArticle`/`runSummarize` signatures match between the writer (Task 4) and the coordinator call sites (Task 5). `canonicalCreatedAtSnapshot()` (Task 3) and `snapshotMarks()` (Task 5 Step 2) are used exactly as defined. `AggregationService.parseBlocks`/`userFacingMessage` remain on the service and are called by the writer.
