# Phase 4a — Aggregation Orchestration Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub `AggregationService` with a real orchestration engine — per-feed run cap, upsert/dedup with tag snapshotting, intake age filter, retention cleanup, credential resolution, and error-isolated runs — all testable against a fake aggregator with no network.

**Architecture:** The `@MainActor` `AggregationService` reads each `Feed`, builds a `Sendable` `FeedConfig` snapshot, resolves Keychain credentials, asks an injectable factory for an `Aggregator`, runs `aggregate()` (async, off-main in real aggregators), then filters/caps/upserts the returned `AggregatedArticle`s back on the main actor. Pure logic (run cap, intake window) and SwiftData mutations (upsert, retention) live in small focused units, each unit-tested. Concrete aggregators and networking arrive in Phase 4b; here the registry factory returns `nil` (recorded as a per-feed error) and tests inject a fake.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftData, Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-06-16-local-aggregator-phase4-design.md` (§1, §2, decisions 1–2).

---

## File Structure

- Create `Yana/Aggregators/FeedConfig.swift` — `Sendable` per-run snapshot + factory typealias.
- Create `Yana/Aggregators/AggregationLogic.swift` — pure functions: `runLimit`, `isWithinIntakeWindow`.
- Create `Yana/Aggregators/ArticleUpsert.swift` — insert/update with tag snapshot + Starred preservation.
- Create `Yana/Aggregators/RetentionCleanup.swift` — age-based deletion except Starred.
- Modify `Yana/Aggregators/Aggregator.swift` — simplify the `Aggregator` protocol.
- Modify `Yana/Aggregators/AggregatorRegistry.swift` — factory keyed on `FeedConfig`.
- Modify `Yana/Services/AggregationService.swift` — real implementation (stable public API).
- Create `YanaTests/FeedConfigTests.swift`, `YanaTests/AggregationLogicTests.swift`,
  `YanaTests/ArticleUpsertTests.swift`, `YanaTests/RetentionCleanupTests.swift`.
- Modify `YanaTests/AggregationServiceTests.swift` — drive the real service with a fake factory.

Build/test commands used throughout:

```
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

To run a single suite, append `-only-testing:YanaTests/<SuiteType>`.

---

## Task 1: `FeedConfig` snapshot + simplified `Aggregator` protocol + factory

**Files:**
- Create: `Yana/Aggregators/FeedConfig.swift`
- Modify: `Yana/Aggregators/Aggregator.swift`
- Modify: `Yana/Aggregators/AggregatorRegistry.swift`
- Test: `YanaTests/FeedConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/FeedConfigTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("FeedConfig")
struct FeedConfigTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func snapshotCopiesFeedFieldsAndCollectedToday() throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://a.com/feed", dailyLimit: 12)
        context.insert(feed)

        let config = FeedConfig(feed: feed, collectedToday: 3)

        #expect(config.type == .feedContent)
        #expect(config.identifier == "https://a.com/feed")
        #expect(config.dailyLimit == 12)
        #expect(config.collectedToday == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedConfigTests`
Expected: FAIL — `cannot find 'FeedConfig' in scope`.

- [ ] **Step 3: Create `FeedConfig` and the factory typealias**

Create `Yana/Aggregators/FeedConfig.swift`:

```swift
import Foundation

/// Immutable, `Sendable` snapshot of everything an aggregator needs for one run.
/// Built on the main actor from a SwiftData `Feed`, then handed to an aggregator that
/// may run off the main actor. Aggregators never touch SwiftData directly.
struct FeedConfig: Sendable {
    var type: AggregatorType
    var identifier: String
    var dailyLimit: Int
    var options: AggregatorOptions
    /// Number of articles already imported for this feed since the start of today.
    var collectedToday: Int

    @MainActor
    init(feed: Feed, collectedToday: Int) {
        self.type = feed.type
        self.identifier = feed.identifier
        self.dailyLimit = feed.dailyLimit
        self.options = feed.options
        self.collectedToday = collectedToday
    }

    /// Memberwise init for tests and future call sites.
    init(type: AggregatorType, identifier: String, dailyLimit: Int, options: AggregatorOptions, collectedToday: Int) {
        self.type = type
        self.identifier = identifier
        self.dailyLimit = dailyLimit
        self.options = options
        self.collectedToday = collectedToday
    }
}

/// Builds an `Aggregator` for a run, or `nil` if no concrete aggregator is registered yet.
/// Phase 4b–4e populate the registry; the service records `nil` as a per-feed error.
typealias AggregatorFactory = @Sendable (FeedConfig, AggregatorCredentials) -> (any Aggregator)?
```

- [ ] **Step 4: Simplify the `Aggregator` protocol**

In `Yana/Aggregators/Aggregator.swift`, replace the `protocol Aggregator { ... }` block with:

```swift
/// A pluggable content source. Concrete implementations land in Phase 4b+.
/// Constructed by an `AggregatorFactory` that captures its `FeedConfig` + credentials.
protocol Aggregator: Sendable {
    /// Validate configuration before a run. Throws if the feed is misconfigured.
    func validate() throws

    /// Fetch and return articles for the feed.
    func aggregate() async throws -> [AggregatedArticle]
}
```

(Leave `AggregatorCredentials` and `enum AggregatorError` in this file unchanged.)

- [ ] **Step 5: Update the registry to the new factory shape**

Replace the body of `Yana/Aggregators/AggregatorRegistry.swift` with:

```swift
import Foundation

/// Maps a `FeedConfig` to a concrete `Aggregator`. Phase 4b+ fills in the `switch`.
final class AggregatorRegistry: Sendable {
    static let shared = AggregatorRegistry()

    private init() {}

    /// Build an aggregator for the given config, or `nil` if none is registered yet.
    func makeAggregator(_ config: FeedConfig, credentials: AggregatorCredentials) -> (any Aggregator)? {
        // Phase 4b+: switch over `config.type` and return concrete aggregators.
        nil
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/FeedConfigTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Yana/Aggregators/FeedConfig.swift Yana/Aggregators/Aggregator.swift Yana/Aggregators/AggregatorRegistry.swift YanaTests/FeedConfigTests.swift
git commit -m "feat: FeedConfig snapshot + aggregator factory seam"
```

---

## Task 2: Pure orchestration logic — run cap + intake window

**Files:**
- Create: `Yana/Aggregators/AggregationLogic.swift`
- Test: `YanaTests/AggregationLogicTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/AggregationLogicTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("AggregationLogic")
struct AggregationLogicTests {
    @Test func runLimitSubtractsCollectedToday() {
        #expect(AggregationLogic.runLimit(dailyLimit: 20, collectedToday: 5) == 15)
    }

    @Test func runLimitNeverNegative() {
        #expect(AggregationLogic.runLimit(dailyLimit: 10, collectedToday: 25) == 0)
    }

    @Test func intakeWindowKeepsRecentAndFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let recent = now.addingTimeInterval(-10 * 24 * 3600)   // 10 days old
        let future = now.addingTimeInterval(3600)
        #expect(AggregationLogic.isWithinIntakeWindow(recent, now: now))
        #expect(AggregationLogic.isWithinIntakeWindow(future, now: now))
    }

    @Test func intakeWindowDropsOld() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let old = now.addingTimeInterval(-61 * 24 * 3600)      // 61 days old
        #expect(AggregationLogic.isWithinIntakeWindow(old, now: now) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationLogicTests`
Expected: FAIL — `cannot find 'AggregationLogic' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Yana/Aggregators/AggregationLogic.swift`:

```swift
import Foundation

/// Pure, side-effect-free orchestration helpers. Easy to unit-test in isolation.
enum AggregationLogic {
    /// Flat per-run cap: fetch up to `dailyLimit` minus what was already collected today.
    /// (Spec decision 2 — the server's adaptive time-of-day quota is intentionally dropped.)
    static func runLimit(dailyLimit: Int, collectedToday: Int) -> Int {
        max(0, dailyLimit - collectedToday)
    }

    /// Intake age filter (spec §2): keep articles whose publish date is no older than
    /// `maxAgeDays`. Unlike the server, the date is NOT rewritten — this only filters.
    static func isWithinIntakeWindow(_ date: Date, now: Date, maxAgeDays: Int = 60) -> Bool {
        date >= now.addingTimeInterval(-Double(maxAgeDays) * 24 * 3600)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationLogicTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/AggregationLogic.swift YanaTests/AggregationLogicTests.swift
git commit -m "feat: pure run-cap + intake-window logic"
```

---

## Task 3: `ArticleUpsert` — dedup, tag snapshot, Starred preservation

**Files:**
- Create: `Yana/Aggregators/ArticleUpsert.swift`
- Test: `YanaTests/ArticleUpsertTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ArticleUpsertTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleUpsert")
struct ArticleUpsertTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func aggregated(_ id: String, title: String = "T", content: String = "C", date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: title, identifier: id, url: id, rawContent: "", content: content, date: date, author: "", iconURL: nil)
    }

    @Test func insertsNewArticleWithFeedTagSnapshot() throws {
        let context = try makeContext()
        let news = Yana.Tag(name: "News")
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "f")
        feed.tags = [news]
        context.insert(feed)

        ArticleUpsert.apply([aggregated("x1")], to: feed, starredTag: nil, context: context, now: .now)

        #expect(feed.articles.count == 1)
        #expect(feed.articles.first?.tags.map(\.name) == ["News"])
    }

    @Test func updatesExistingByIdentifierAndPreservesStar() throws {
        let context = try makeContext()
        let starred = Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true)
        let news = Yana.Tag(name: "News")
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "f")
        feed.tags = [news]
        context.insert(feed); context.insert(starred)

        // First import, then user stars it.
        ArticleUpsert.apply([aggregated("x1", content: "old")], to: feed, starredTag: starred, context: context, now: .now)
        let article = try #require(feed.articles.first)
        article.setStarred(true, using: starred)
        let originalCreatedAt = article.createdAt

        // Re-import the same identifier with new content.
        ArticleUpsert.apply([aggregated("x1", content: "new")], to: feed, starredTag: starred, context: context, now: .now.addingTimeInterval(60))

        #expect(feed.articles.count == 1)                 // no duplicate
        #expect(article.content == "new")                 // content refreshed
        #expect(article.isStarred)                         // star survived re-import
        #expect(article.tags.contains { $0.name == "News" })
        #expect(article.createdAt == originalCreatedAt)    // timeline position preserved
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleUpsertTests`
Expected: FAIL — `cannot find 'ArticleUpsert' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Yana/Aggregators/ArticleUpsert.swift`:

```swift
import Foundation
import SwiftData

/// Inserts or updates `Article`s from aggregated results, deduping by `(feed, identifier)`.
/// Tags are snapshotted from the feed at import; the user's Starred tag survives re-imports.
enum ArticleUpsert {
    @MainActor
    static func apply(
        _ aggregated: [AggregatedArticle],
        to feed: Feed,
        starredTag: Tag?,
        context: ModelContext,
        now: Date
    ) {
        for item in aggregated {
            if let existing = feed.articles.first(where: { $0.identifier == item.identifier }) {
                // Update: refresh content; re-snapshot feed tags; preserve Starred.
                let wasStarred = existing.isStarred
                existing.title = item.title
                existing.url = item.url
                existing.rawContent = item.rawContent
                existing.content = item.content
                existing.author = item.author
                existing.iconURL = item.iconURL
                existing.date = item.date
                existing.tags = feed.tags
                if wasStarred, let starredTag, !existing.tags.contains(where: { $0.id == starredTag.id }) {
                    existing.tags.append(starredTag)
                }
                // createdAt left untouched — preserves the reader's timeline position.
            } else {
                // Insert: snapshot the feed's current tags.
                let article = Article(
                    title: item.title,
                    identifier: item.identifier,
                    url: item.url,
                    rawContent: item.rawContent,
                    content: item.content,
                    date: item.date,
                    author: item.author,
                    iconURL: item.iconURL
                )
                article.createdAt = now
                article.feed = feed
                context.insert(article)
                article.tags = feed.tags
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleUpsertTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/ArticleUpsert.swift YanaTests/ArticleUpsertTests.swift
git commit -m "feat: article upsert with tag snapshot + Starred preservation"
```

---

## Task 4: `RetentionCleanup` — delete old articles except Starred

**Files:**
- Create: `Yana/Aggregators/RetentionCleanup.swift`
- Test: `YanaTests/RetentionCleanupTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/RetentionCleanupTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("RetentionCleanup")
struct RetentionCleanupTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func article(_ id: String, createdAt: Date) -> Article {
        let a = Article(title: id, identifier: id, url: id)
        a.createdAt = createdAt
        return a
    }

    @Test func deletesOldUnstarredKeepsRecentAndStarred() throws {
        let context = try makeContext()
        let starred = Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true)
        context.insert(starred)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        let recent = article("recent", createdAt: now.addingTimeInterval(-5 * 24 * 3600))
        let old = article("old", createdAt: now.addingTimeInterval(-40 * 24 * 3600))
        let oldStarred = article("oldStarred", createdAt: now.addingTimeInterval(-40 * 24 * 3600))
        context.insert(recent); context.insert(old); context.insert(oldStarred)
        oldStarred.tags = [starred]

        RetentionCleanup.run(context: context, retentionDays: 30, now: now)

        let remaining = try context.fetch(FetchDescriptor<Article>()).map(\.identifier).sorted()
        #expect(remaining == ["oldStarred", "recent"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RetentionCleanupTests`
Expected: FAIL — `cannot find 'RetentionCleanup' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Yana/Aggregators/RetentionCleanup.swift`:

```swift
import Foundation
import SwiftData

/// Deletes articles older than the retention window, except those the user has Starred.
/// (Spec §2 — age is the only cleanup criterion; there is no read/unread state.)
enum RetentionCleanup {
    @MainActor
    static func run(context: ModelContext, retentionDays: Int, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.createdAt < cutoff })
        let candidates = (try? context.fetch(descriptor)) ?? []
        for article in candidates where !article.isStarred {
            context.delete(article)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RetentionCleanupTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Aggregators/RetentionCleanup.swift YanaTests/RetentionCleanupTests.swift
git commit -m "feat: age-based retention cleanup (Starred exempt)"
```

---

## Task 5: Credential resolution from Keychain

**Files:**
- Modify: `Yana/Aggregators/Aggregator.swift`
- Test: `YanaTests/AggregationServiceTests.swift` (added in Task 6; credential resolver tested there)

- [ ] **Step 1: Add the resolver to `AggregatorCredentials`**

In `Yana/Aggregators/Aggregator.swift`, replace the `AggregatorCredentials` struct with:

```swift
/// Resolved secrets handed to an aggregator at construction time.
struct AggregatorCredentials: Sendable {
    var redditClientID: String?
    var redditClientSecret: String?
    var youtubeAPIKey: String?

    /// Read the user-supplied API keys out of the Keychain. Empty strings map to `nil`.
    static func resolved() -> AggregatorCredentials {
        func nonEmpty(_ item: KeychainService.APIKeyItem) -> String? {
            let value = KeychainService.loadAPIKey(for: item)
            return (value?.isEmpty == false) ? value : nil
        }
        return AggregatorCredentials(
            redditClientID: nonEmpty(.redditClientID),
            redditClientSecret: nonEmpty(.redditClientSecret),
            youtubeAPIKey: nonEmpty(.youtubeAPIKey)
        )
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. (Resolver behavior is exercised in Task 6's service tests.)

- [ ] **Step 3: Commit**

```bash
git add Yana/Aggregators/Aggregator.swift
git commit -m "feat: resolve aggregator credentials from Keychain"
```

---

## Task 6: `AggregationService` real implementation

**Files:**
- Modify: `Yana/Services/AggregationService.swift`
- Modify: `YanaTests/AggregationServiceTests.swift`

- [ ] **Step 1: Write the failing tests (with a fake aggregator)**

Replace the entire contents of `YanaTests/AggregationServiceTests.swift` with:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationService")
struct AggregationServiceTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Fake aggregator returning canned articles (no network).
    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        var validateError: Error?
        func validate() throws { if let validateError { throw validateError } }
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }

    private func aggregated(_ id: String, date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: id, identifier: id, url: id, rawContent: "", content: "c", date: date, author: "", iconURL: nil)
    }

    @Test func updateAllImportsArticlesFromEnabledFeedsOnly() async throws {
        let context = try makeContext()
        let enabled = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        let disabled = Feed(name: "B", aggregatorType: .feedContent, identifier: "b", enabled: false)
        context.insert(enabled); context.insert(disabled)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
        }
        await service.updateAll()

        #expect(service.isUpdating == false)
        #expect(enabled.articles.count == 2)
        #expect(disabled.articles.isEmpty)
        #expect(enabled.lastFetchedAt != nil)
        #expect(enabled.lastError == nil)
    }

    @Test func runCapLimitsImportedArticles() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
        }
        await service.update(feed: feed)

        #expect(feed.articles.count == 2)
    }

    @Test func dropsArticlesOlderThanIntakeWindow() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let old = aggregated("old", date: Date.now.addingTimeInterval(-61 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("fresh"), old])
        }
        await service.update(feed: feed)

        #expect(feed.articles.map(\.identifier) == ["fresh"])
    }

    @Test func feedFailureIsIsolatedAndRecorded() async throws {
        let context = try makeContext()
        let bad = Feed(name: "bad", aggregatorType: .feedContent, identifier: "bad")
        let good = Feed(name: "good", aggregatorType: .feedContent, identifier: "good")
        context.insert(bad); context.insert(good)

        let service = AggregationService(context: context) { config, _ in
            if config.identifier == "bad" {
                return FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
            }
            return FakeAggregator(articles: [self.aggregated("g1")])
        }
        await service.updateAll()

        #expect(bad.lastError != nil)
        #expect(good.articles.count == 1)        // one feed's failure didn't abort the run
        #expect(good.lastError == nil)
    }

    @Test func missingAggregatorRecordsError() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)

        // Default factory (registry) returns nil until Phase 4b.
        let service = AggregationService(context: context)
        await service.update(feed: feed)

        #expect(feed.lastError != nil)
        #expect(feed.articles.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests`
Expected: FAIL — the `AggregationService(context:makeAggregator:)` initializer does not exist yet.

- [ ] **Step 3: Write the real implementation**

Replace the entire contents of `Yana/Services/AggregationService.swift` with:

```swift
import Foundation
import SwiftData

/// Orchestrates on-device aggregation: builds a per-feed snapshot, runs its aggregator,
/// then filters / caps / upserts the results. Concrete aggregators arrive in Phase 4b+;
/// until then the default factory returns `nil` and each feed records a "not available" error.
@MainActor
@Observable
final class AggregationService {
    var isUpdating = false

    private let context: ModelContext
    private let makeAggregator: AggregatorFactory
    private let now: () -> Date

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.now = now
    }

    /// Update all enabled feeds. One feed's failure never aborts the run.
    func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = (try? context.fetch(descriptor)) ?? []
        for feed in feeds {
            await aggregate(feed: feed)
        }
        cleanupAndSave()
    }

    /// Update a single feed.
    func update(feed: Feed) async {
        isUpdating = true
        defer { isUpdating = false }
        await aggregate(feed: feed)
        cleanupAndSave()
    }

    /// Re-fetch and re-process a single article by re-running its owning feed.
    /// (Phase 4b refines this to a true single-article re-fetch.)
    func update(article: Article) async {
        guard let feed = article.feed else { return }
        await update(feed: feed)
    }

    // MARK: - Core per-feed run

    private func aggregate(feed: Feed) async {
        let runNow = now()
        let collected = collectedToday(for: feed, now: runNow)
        let config = FeedConfig(feed: feed, collectedToday: collected)
        let credentials = AggregatorCredentials.resolved()

        guard let aggregator = makeAggregator(config, credentials) else {
            feed.lastError = AggregatorError.notImplemented(feed.type).errorDescription
            return
        }

        do {
            try aggregator.validate()
            let fetched = try await aggregator.aggregate()
            let fresh = fetched.filter { AggregationLogic.isWithinIntakeWindow($0.date, now: runNow) }
            let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
            let capped = Array(fresh.prefix(cap))
            ArticleUpsert.apply(capped, to: feed, starredTag: starredTag(), context: context, now: runNow)
            feed.lastFetchedAt = runNow
            feed.lastError = nil
        } catch {
            feed.lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func collectedToday(for feed: Feed, now: Date) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: now)
        return feed.articles.filter { $0.createdAt >= startOfDay }.count
    }

    private func starredTag() -> Tag? {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        return (try? context.fetch(descriptor))?.first
    }

    private func cleanupAndSave() {
        let retentionDays = AppSettings().retentionDays
        RetentionCleanup.run(context: context, retentionDays: retentionDays, now: now())
        try? context.save()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AggregationServiceTests`
Expected: PASS (all five tests).

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS. (Existing callers in `FeedsView.swift` and `ArticleReaderView.swift` use the unchanged `init(context:)` / `updateAll()` / `update(feed:)` / `update(article:)` API and still compile.)

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/AggregationService.swift YanaTests/AggregationServiceTests.swift
git commit -m "feat: real AggregationService orchestration (cap, upsert, retention, error isolation)"
```

---

## Notes for Phase 4b (not part of 4a)

- `AppSettings().retentionDays` is read on the main actor inside `cleanupAndSave()`; if a
  test harness needs a custom retention window, inject `AppSettings` into the service then.
- `update(article:)` currently re-runs the whole owning feed. Phase 4b replaces this with a
  true single-article re-fetch once the `FullWebsiteAggregator` per-article path exists.
- The registry's `makeAggregator` returns `nil` for every type until Phase 4b wires concretes;
  real feeds therefore record a "not available yet" error — expected at this stage.
- Cached-image cleanup hooks into `RetentionCleanup` in Phase 4b (when the image pipeline lands).

---

## Self-Review

**Spec coverage (4a scope):** run cap (Task 2 + 6), intake filter (Task 2 + 6), upsert/dedup/tag
snapshot + Starred preservation (Task 3), retention except Starred (Task 4), credential
resolution (Task 5), error-isolated orchestration + `update(article:)` (Task 6), `FeedConfig`
snapshot + factory seam (Task 1). All covered.

**Placeholders:** none — every step shows complete code or an exact command + expected result.

**Type consistency:** `FeedConfig`, `AggregatorFactory`, `AggregatorCredentials.resolved()`,
`AggregationLogic.runLimit/isWithinIntakeWindow`, `ArticleUpsert.apply`, `RetentionCleanup.run`,
and `AggregationService(context:makeAggregator:now:)` are referenced with identical signatures
across tasks. The `Aggregator` protocol (`validate()` + `aggregate()`) matches the `FakeAggregator`
in Task 6. `Yana.Tag` is namespaced in tests to avoid collision with SwiftData/Foundation `Tag`.
