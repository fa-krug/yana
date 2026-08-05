# Read-State Sort, Mark-Read, Offline Write Queue, Unread Badge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Use the server's existing `read` field to sort the timeline read-articles-first/unread-second (oldest→newest within each), mark articles read automatically as the user reads them on iOS and Mac, replace the star/read PATCH rollback-on-failure pattern with a small offline retry queue, and add an opt-in app-icon unread badge.

**Architecture:** `Article` gains a persisted `readRank: Int` (0=read, 1=unread) kept in sync with a new `read: Bool` via an explicit `setRead(_:)` method (not a property observer — see Task 1). Every fetch/merge that currently orders by `createdAt` alone becomes a compound `(readRank, createdAt)` order. A new `ArticleWrites` facade centralizes the optimistic-local-write-then-PATCH pattern for both `starred` and `read`, enqueuing into a new `PendingWriteQueue` (stored in `AppSettings`) on failure instead of rolling back; `SyncEngine.sync()` flushes that queue before its normal pull. Mark-read hooks fire from the iOS pager's page-transition-completed callback and from Mac's `TimelineModel` selection changes. A new `UnreadBadgeUpdater` recomputes the app-icon badge from `ArticleStore.publish(_:)`, respecting the user's current timeline filter.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, UIKit (iOS + Mac Catalyst), Swift Testing (`@testable import Yana`).

## Global Constraints

- Every new/changed user-facing string needs a `Localizable.xcstrings` entry translated into German (`"state": "translated"`), per this repo's translation rule — this plan introduces exactly one (`NotificationsSettingsSection`'s new toggle label).
- `@ModelActor` types run on the caller's thread; any call into `SyncWriter` from `@MainActor` code must go through `OffMainActor.run` (already the pattern in `SyncEngine`; no new call sites need this in this plan since all new `SyncWriter` logic lives inside its existing methods).
- Do not use Swift property observers (`didSet`/`willSet`) on `@Model`-declared stored properties — this codebase's existing multi-field-write pattern (`Article.blocks`) always uses a plain computed property or method wrapping the macro-managed stored properties, never an observer on one of them directly. Task 1 follows this: `readRank` is a second real stored property kept in sync via an explicit `setRead(_:)` method, not a `didSet` on `read`.
- All new Swift files start with the same two-space-indent, no-header-comment style already used throughout `Yana/Services/` and `Yana/Utilities/`.

---

### Task 1: `Article` model — `read`/`readRank`/`setRead`

**Files:**
- Modify: `Yana/Models/Article.swift`

**Interfaces:**
- Produces: `Article.read: Bool` (default `false`), `Article.readRank: Int` (default `1`), `Article.setRead(_ value: Bool)` — the only way `read`/`readRank` should be mutated after this task (every later task that flips read state calls this method, never `article.read = ...` directly).

- [ ] **Step 1: Add the fields and the `#Index` entry**

In `Yana/Models/Article.swift`, update the `#Index` macro call (line 12) to include `readRank`:

```swift
#Index<Article>([\.createdAt], [\.identifier], [\.serverID], [\.readRank])
```

Add the two new stored properties right after `starred` (currently line 43):

```swift
var starred: Bool = false
/// Whether the server (or a local mark-as-read) considers this article read. Drives the
/// timeline's primary sort key via `readRank` — see that property's doc comment. Never assign
/// this directly; always go through `setRead(_:)` so `readRank` stays in sync (SwiftData's
/// `@Model` macro fully owns this property's accessors, so a `didSet` here is not an option —
/// same reason `blocks` below is a separate plain computed property rather than an observer on
/// `blockData`).
var read: Bool = false
/// Mirrors `read` as a `SortDescriptor`-sortable key: `0` when read, `1` when unread. Exists only
/// because `Bool` does not conform to `Comparable`, so `SortDescriptor(\.read)` cannot compile —
/// every fetch that orders the timeline sorts by this ascending, then by `createdAt` ascending,
/// giving "read (oldest→newest), then unread (oldest→newest)". Kept in sync with `read`
/// exclusively by `setRead(_:)`.
var readRank: Int = 1
```

- [ ] **Step 2: Add `setRead(_:)`**

Add this method right after the `init` (after line 84, before the `blocks` computed property):

```swift
/// The only supported way to change `read` — keeps `readRank` in sync. See `readRank`'s doc
/// comment for why a property observer isn't used instead.
func setRead(_ value: Bool) {
    read = value
    readRank = value ? 0 : 1
}
```

- [ ] **Step 3: Build to confirm the migration is lightweight**

Run: `xcodegen generate && xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: build succeeds. (New `@Model` properties with default values are additive/lightweight migrations, matching every other field added to `Article` post-launch — no `VersionedSchema` bump needed, per the existing pattern documented on `starred`/`hasContent`/etc.)

- [ ] **Step 4: Commit**

```bash
git add Yana/Models/Article.swift
git commit -m "Add Article.read/readRank + setRead(_:)"
```

---

### Task 2: `ArticleSummary.isRead`

**Files:**
- Modify: `Yana/Models/ArticleSummary.swift`
- Test: `YanaTests/ArticleSummaryTests.swift` (create if it doesn't already exist — check first with `find YanaTests -iname 'ArticleSummaryTests.swift'`; if it exists, add to it instead)

**Interfaces:**
- Consumes: `Article.read` (Task 1).
- Produces: `ArticleSummary.isRead: Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSummary")
struct ArticleSummaryTests {
    @Test func isReadMirrorsArticleRead() throws {
        let container = try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let article = Article(title: "T", identifier: "id-1", url: "https://x.com/1")
        article.setRead(true)
        context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)
        #expect(summary.isRead == true)
    }

    @Test func isReadRoundTripsThroughCoding() throws {
        let container = try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let article = Article(title: "T", identifier: "id-2", url: "https://x.com/2")
        article.setRead(true)
        context.insert(article)
        try context.save()

        let summary = ArticleSummary(article)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ArticleSummary.self, from: data)
        #expect(decoded.isRead == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummaryTests`
Expected: FAIL to compile — `ArticleSummary` has no member `isRead`.

- [ ] **Step 3: Implement**

In `Yana/Models/ArticleSummary.swift`:

Add the field after `isStarred` (line 21):
```swift
let isStarred: Bool
let isRead: Bool
```

In `init(_ article:tagNamesByID:)`, after `isStarred = article.starred` (line 42):
```swift
isStarred = article.starred
isRead = article.read
```

Add `isRead` to `CodingKeys` (line 47):
```swift
case identifier, title, feedName, feedLogoHash, author, date, createdAt, tagNames, isStarred, isRead
```

In `init(from decoder:)`, after decoding `isStarred` (line 61):
```swift
isStarred = try c.decode(Bool.self, forKey: .isStarred)
isRead = try c.decode(Bool.self, forKey: .isRead)
```

In `encode(to:)`, after encoding `isStarred` (line 74):
```swift
try c.encode(isStarred, forKey: .isStarred)
try c.encode(isRead, forKey: .isRead)
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleSummaryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/ArticleSummary.swift YanaTests/ArticleSummaryTests.swift
git commit -m "Add ArticleSummary.isRead"
```

---

### Task 3: `TimelineFiltering` — `filterRead` + doc fix

**Files:**
- Modify: `Yana/Utilities/TimelineFiltering.swift`
- Test: `YanaTests/TimelineFilteringTests.swift`

**Interfaces:**
- Consumes: `Article.read` (Task 1), `ArticleSummary.isRead` (Task 2).
- Produces: `TimelineFilterable.filterRead: Bool` (both conformances).

No new filter *type* is added — only the protocol property, for symmetry with `filterStarred`, as documented in the spec's explicit out-of-scope note (no unread-only toggle yet).

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/TimelineFilteringTests.swift`, reusing its existing `article(_:tagIDs:in:)` helper (lines 21-29):

```swift
@Test func filterReadMirrorsReadOnArticleAndSummary() throws {
    let context = try makeContext()
    let a = article("a", tagIDs: [], in: context)
    a.setRead(true)
    #expect(a.filterRead == true)

    let summary = ArticleSummary(a)
    #expect(summary.filterRead == true)
    #expect(summary.filterRead == summary.isRead)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineFilteringTests`
Expected: FAIL to compile — no member `filterRead`.

- [ ] **Step 3: Implement**

In `Yana/Utilities/TimelineFiltering.swift`, add to the protocol (line 6-10):
```swift
protocol TimelineFilterable {
    var filterTagNames: [String] { get }
    var filterFeedName: String? { get }
    var filterStarred: Bool { get }
    var filterRead: Bool { get }
}
```

Add to the `Article` conformance (after line 38, `var filterStarred: Bool { starred }`):
```swift
var filterStarred: Bool { starred }
var filterRead: Bool { read }
```

Add to the `ArticleSummary` conformance (after line 46, `var filterStarred: Bool { isStarred }`):
```swift
var filterStarred: Bool { isStarred }
var filterRead: Bool { isRead }
```

Update `TimelineAnchor`'s doc comment (lines 96-102) — it currently says "falls back to the newest item (last index in the ascending timeline)", which is stale once the sort is no longer pure-ascending-by-date:
```swift
/// Resolves the persisted timeline anchor to an index in the displayed list, falling back
/// to the last item (the newest unread article, or the newest read article if none are unread)
/// when missing.
enum TimelineAnchor {
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineFilteringTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Utilities/TimelineFiltering.swift YanaTests/TimelineFilteringTests.swift
git commit -m "Add TimelineFilterable.filterRead"
```

---

### Task 4: Compound sort order (`readRank`, `createdAt`)

**Files:**
- Modify: `Yana/Services/ArticleStore.swift` (the `ArticleSummaryLoader` fetch descriptors)
- Modify: `Yana/Services/SummaryIndexMerge.swift`
- Modify: `YanaTests/TimelineOrderingTests.swift`
- Modify: `YanaTests/SummaryIndexMergeTests.swift`

**Interfaces:**
- Consumes: `Article.readRank` (Task 1), `ArticleSummary.isRead`/`createdAt` (Task 2, existing).
- Produces: nothing new — this task changes *behavior* of existing fetch/merge functions, not their signatures.

This is the task that actually changes what order the timeline displays in, so it touches the two places order is decided: the SwiftData fetch (`ArticleSummaryLoader`, used by `ArticleStore.fullLoad`/`publishFastDataset`) and the in-memory splice merge (`SummaryIndexMerge.apply`, used by `ArticleStore.splice`).

- [ ] **Step 1: Update the failing/now-wrong existing tests first**

Replace `YanaTests/TimelineOrderingTests.swift`'s single test with one that asserts the new compound order, including a read/unread split:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

/// Timeline ordering: `ArticleSummaryLoader` (used by `ArticleStore`) fetches articles read-first
/// (oldest→newest), then unread (oldest→newest) — see `Article.readRank`'s doc comment. This is
/// the canonical display order for both the reader pager and the article list view that reads
/// `store.summaries` directly.
@MainActor
@Suite("Timeline ordering")
struct TimelineOrderingTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    private func insertArticle(_ id: String, createdAt: Date, read: Bool, into context: ModelContext) {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.createdAt = createdAt
        a.setRead(read)
        context.insert(a)
    }

    private func seed(_ context: ModelContext) {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Unread, newest by date -- must still sort AFTER every read article.
        insertArticle("unread-new", createdAt: base.addingTimeInterval(300), read: false, into: context)
        // Read, oldest by date -- must sort first overall.
        insertArticle("read-old", createdAt: base, read: true, into: context)
        // Unread, oldest unread -- must sort right after the read block.
        insertArticle("unread-old", createdAt: base.addingTimeInterval(100), read: false, into: context)
        // Read, newest read -- must sort right before the unread block.
        insertArticle("read-new", createdAt: base.addingTimeInterval(200), read: true, into: context)
    }

    @Test func articleStoreFetchDescriptorIsReadThenUnreadByCreatedAt() throws {
        let context = try makeContext()
        seed(context)

        // The ArticleSummaryLoader descriptor: readRank ascending, then createdAt ascending.
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.readRank, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.readRank]
        let fetched = try context.fetch(descriptor)
        #expect(fetched.map(\.identifier) == ["read-old", "read-new", "unread-old", "unread-new"])
    }
}
```

Replace `YanaTests/SummaryIndexMergeTests.swift`'s `rows(_:)` helper and every test that asserts a specific order so they account for read state. Change `rows(_:)` to accept per-row read state and default every row to unread (preserving today's tests' intent — they were only ever testing `createdAt` ordering within a single read-state group):

```swift
private static func rows(_ count: Int, read: Bool = false) throws -> (ModelContainer, [Article], [ArticleSummary]) {
    let container = try ModelContainer(
        for: Feed.self, Tag.self, Article.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    let feed = Feed(name: "F", aggregator: "feedContent", identifier: "f")
    context.insert(feed)
    var articles: [Article] = []
    for i in 0..<count {
        let a = Article(title: "A\(i)", identifier: "a\(i)", url: "u\(i)",
                        date: Date(timeIntervalSince1970: Double(i)))
        a.createdAt = Date(timeIntervalSince1970: Double(i) * 10)
        a.setRead(read)
        a.feed = feed
        context.insert(a)
        articles.append(a)
    }
    try context.save()
    return (container, articles, articles.map { ArticleSummary($0) })
}
```

Every existing call to `Self.rows(_:)` in that file keeps compiling unchanged (the new parameter defaults to `false`, matching the old implicit all-unread behavior), so `insertLandsInCreatedAtOrder`, `changedRowMovesToItsNewPosition`, `removedRowsAreDropped`, `mergePreservesAscendingOrderWithManyChanges`, `emptyChangeIsANoOp`, `spliceabilityRequiresPersistentIDs`, and `emptyIndexIsSpliceable` all still pass once Step 3 below preserves same-read-state ordering exactly as before. Add one new test proving the compound key itself:

```swift
@Test func mergeOrdersReadBeforeUnreadRegardlessOfCreatedAt() throws {
    let (container, _, _) = try Self.rows(0)
    let context = ModelContext(container)
    let feed = try context.fetch(FetchDescriptor<Feed>()).first!

    let unreadOld = Article(title: "UnreadOld", identifier: "uo", url: "u",
                            date: Date(timeIntervalSince1970: 0))
    unreadOld.createdAt = Date(timeIntervalSince1970: 0)
    unreadOld.feed = feed
    context.insert(unreadOld)

    let readNew = Article(title: "ReadNew", identifier: "rn", url: "u",
                          date: Date(timeIntervalSince1970: 100))
    readNew.createdAt = Date(timeIntervalSince1970: 100)
    readNew.setRead(true)
    readNew.feed = feed
    context.insert(readNew)
    try context.save()

    let merged = SummaryIndexMerge.apply(
        to: [], changed: [ArticleSummary(unreadOld), ArticleSummary(readNew)], removed: []
    )
    // readNew is read (rank 0) and unreadOld is unread (rank 1) -- read must come first even
    // though unreadOld's createdAt is earlier.
    #expect(merged.map(\.identifier) == ["rn", "uo"])
}
```

- [ ] **Step 2: Run to verify the new/changed tests fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineOrderingTests -only-testing:YanaTests/SummaryIndexMergeTests`
Expected: `articleStoreFetchDescriptorIsReadThenUnreadByCreatedAt` and `mergeOrdersReadBeforeUnreadRegardlessOfCreatedAt` FAIL (old code still sorts by `createdAt` alone); the rest still PASS (they don't yet exercise mixed read state).

- [ ] **Step 3: Implement**

In `Yana/Services/ArticleStore.swift`, `ArticleSummaryLoader.load()` (line 9-11):
```swift
var descriptor = FetchDescriptor<Article>(
    sortBy: [SortDescriptor(\.readRank, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
)
```
Add `\.readRank` to `propertiesToFetch` (line 14):
```swift
descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.readRank]
```

In `lightDescriptor(predicate:order:)` (lines 86-95), same two changes:
```swift
private func lightDescriptor(
    predicate: Predicate<Article>?, order: SortOrder
) -> FetchDescriptor<Article> {
    var d = FetchDescriptor<Article>(
        predicate: predicate,
        sortBy: [SortDescriptor(\.readRank, order: order), SortDescriptor(\.createdAt, order: order)]
    )
    d.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.readRank]
    d.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
    return d
}
```
(`loadWindow`'s anchor-relative predicates — `$0.createdAt >= anchorDate` / `$0.createdAt < anchorDate` — stay unchanged: they still select *which* rows fall in the fast-path window by date, same as today; only the order those rows come back in changes to the compound key via this shared helper. Per the design spec, the cold-cache window is explicitly a provisional first paint that the very next `refreshNow()` reconciles against the full, correctly-ordered index, so an approximate window here is acceptable.)

In `Yana/Services/SummaryIndexMerge.swift`, replace the `createdAt`-only comparisons with a compound comparator. Replace the whole file's `apply` method body and add a private helper:

```swift
/// Apply `changed` (re-read rows) and `removed` (deleted rows) to a `(readRank, createdAt)`
/// ascending index -- read articles (oldest→newest), then unread articles (oldest→newest).
///
/// Ties keep the incoming row *after* the existing ones. SQLite gives no guarantee for tied sort
/// keys either, and inserts are jittered across a window (`ArticleUpsert.importJitterWindow`), so
/// exact ties are rare; a later full reconcile settles any disagreement.
static func apply(
    to index: [ArticleSummary],
    changed: [ArticleSummary],
    removed: Set<PersistentIdentifier>
) -> [ArticleSummary] {
    // Every changed row is re-inserted at its (possibly new) position, so drop the old copy too.
    var dropped = removed
    for summary in changed { if let id = summary.persistentID { dropped.insert(id) } }

    let kept = dropped.isEmpty
        ? index
        : index.filter { $0.persistentID.map { !dropped.contains($0) } ?? true }
    guard !changed.isEmpty else { return kept }

    let incoming = changed.sorted(by: isOrderedBefore)
    var merged: [ArticleSummary] = []
    merged.reserveCapacity(kept.count + incoming.count)
    var i = 0, j = 0
    while i < kept.count, j < incoming.count {
        if !isOrderedBefore(incoming[j], kept[i]) {
            merged.append(kept[i]); i += 1
        } else {
            merged.append(incoming[j]); j += 1
        }
    }
    merged.append(contentsOf: kept[i...])
    merged.append(contentsOf: incoming[j...])
    return merged
}

/// The timeline's canonical ordering: read (oldest→newest) before unread (oldest→newest).
/// `Bool` has no `Comparable` conformance, so this can't be a tuple `<` -- written out explicitly.
private static func isOrderedBefore(_ a: ArticleSummary, _ b: ArticleSummary) -> Bool {
    if a.isRead != b.isRead { return a.isRead && !b.isRead }
    return a.createdAt < b.createdAt
}
```

(This preserves the original merge's invariant — `kept[i] <= incoming[j]` becomes `!isOrderedBefore(incoming[j], kept[i])`, i.e. "take from `kept` unless the incoming row strictly precedes it" — exactly the same tie-breaking rule as before, just against the compound key instead of `createdAt` alone.)

Update the file's top doc comment (lines 4-9) to describe the new order:
```swift
/// Splices a small set of changed/removed rows into the timeline index, so a save costs work
/// proportional to what changed rather than to the size of the library.
///
/// The index is the `(readRank, createdAt)`-ascending order `ArticleSummaryLoader.load()`
/// produces (read oldest→newest, then unread oldest→newest — see `Article.readRank`), and this
/// preserves it: one linear merge pass, no re-sort. Rows are identified by `persistentID` —
/// `identifier` is only a per-feed dedup key, so two feeds can legitimately share one.
```

- [ ] **Step 4: Run to verify tests pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineOrderingTests -only-testing:YanaTests/SummaryIndexMergeTests`
Expected: PASS (all of them, including the untouched pre-existing tests, since they only ever used same-read-state rows).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleStore.swift Yana/Services/SummaryIndexMerge.swift YanaTests/TimelineOrderingTests.swift YanaTests/SummaryIndexMergeTests.swift
git commit -m "Sort timeline read-first-then-unread, each oldest-to-newest"
```

---

### Task 5: `SyncWriter` applies `read` with upgrade-only semantics

**Files:**
- Modify: `Yana/Services/SyncWriter.swift`
- Modify: `YanaTests/SyncWriterTests.swift`

**Interfaces:**
- Consumes: `Article.setRead(_:)` (Task 1), `SyncArticleSummaryWire.read` (existing).
- Produces: nothing new — behavior change inside `upsertSummaries`.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/SyncWriterTests.swift` (near the other `upsertSummaries` tests):

```swift
/// "Local wins" rule: a sync pass can upgrade unread→read (the server says another device read
/// it), but must never downgrade an already-locally-read article back to unread.
@Test func upsertNeverDowngradesALocallyReadArticle() async throws {
    let container = try makeContainer()
    let writer = SyncWriter(modelContainer: container)
    let now = Date.now
    _ = await writer.upsertSummaries([
        SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                date: now, author: "", icon: nil, read: false, starred: false,
                                createdAt: now, updatedAt: now)
    ])
    let article = try container.mainContext.fetch(FetchDescriptor<Article>()).first!
    article.setRead(true)
    try container.mainContext.save()

    // A later sync page reports this article as unread (e.g. a stale cache on the server, or a
    // race with another client) -- the local read state must survive.
    _ = await writer.upsertSummaries([
        SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                date: now, author: "", icon: nil, read: false, starred: false,
                                createdAt: now, updatedAt: now.addingTimeInterval(60))
    ])
    #expect(try container.mainContext.fetch(FetchDescriptor<Article>()).first!.read == true)
}

/// The server can upgrade unread -> read (e.g. read from another device).
@Test func upsertAppliesServerReadTrueOnUpdate() async throws {
    let container = try makeContainer()
    let writer = SyncWriter(modelContainer: container)
    let now = Date.now
    _ = await writer.upsertSummaries([
        SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                date: now, author: "", icon: nil, read: false, starred: false,
                                createdAt: now, updatedAt: now)
    ])
    _ = await writer.upsertSummaries([
        SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                date: now, author: "", icon: nil, read: true, starred: false,
                                createdAt: now, updatedAt: now.addingTimeInterval(60))
    ])
    #expect(try container.mainContext.fetch(FetchDescriptor<Article>()).first!.read == true)
}

/// Insert always takes the wire's `read` value unconditionally -- no local state exists yet to protect.
@Test func upsertInsertTakesWireReadValue() async throws {
    let container = try makeContainer()
    let writer = SyncWriter(modelContainer: container)
    let now = Date.now
    _ = await writer.upsertSummaries([
        SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                date: now, author: "", icon: nil, read: true, starred: false,
                                createdAt: now, updatedAt: now)
    ])
    #expect(try container.mainContext.fetch(FetchDescriptor<Article>()).first!.read == true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncWriterTests`
Expected: `upsertNeverDowngradesALocallyReadArticle` FAILs (current code never touches `read` at all, so it stays at whatever default — but more importantly `Article.read` doesn't yet get set anywhere, so this proves the gap either way); the other two new tests also FAIL for the same underlying reason.

- [ ] **Step 3: Implement**

In `Yana/Services/SyncWriter.swift`, `upsertSummaries` (lines 68-96):

Update branch (after `article.starred = summary.starred`, line 76):
```swift
article.starred = summary.starred
if summary.read {
    article.setRead(true)
}
```

Insert branch (after `article.starred = summary.starred`, line 91):
```swift
article.starred = summary.starred
article.setRead(summary.read)
```

Update the method's doc comment (lines 42-44) to mention this:
```swift
/// Upserts by `Article.serverID`. Preserves `createdAt` on update (matches the existing
/// "an article's timeline position never jumps on re-fetch" rule). `read` follows an
/// upgrade-only rule on update -- the wire can flip local unread->read but never read->unread,
/// so a stale/racing sync page can't undo a read the user just made (see `Article.setRead`).
/// Returns the touched rows' `PersistentIdentifier`s so the caller can report progress without a
/// second fetch.
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncWriterTests`
Expected: PASS (all tests in the file, old and new).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/SyncWriter.swift YanaTests/SyncWriterTests.swift
git commit -m "SyncWriter applies read state with upgrade-only semantics"
```

---

### Task 6: `PendingWriteQueue` + `AppSettings.pendingWrites` + `ArticleActions.setRead`

**Files:**
- Create: `Yana/Services/PendingWriteQueue.swift`
- Modify: `Yana/Models/AppSettings.swift`
- Modify: `Yana/Services/ArticleActions.swift`
- Test: `YanaTests/PendingWriteQueueTests.swift` (create)

**Interfaces:**
- Consumes: `ArticleActions.setStarred`/`setRead` (this task adds `setRead`), `AppSettings` (existing pattern).
- Produces: `PendingWriteField` (`.starred(Bool)` / `.read(Bool)`), `PendingWrite { articleServerID: Int, field: PendingWriteField }`, `AppSettings.pendingWrites: [PendingWrite]`, `PendingWriteQueue.enqueue(_:settings:)`, `PendingWriteQueue.flush(using:settings:) async`.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/PendingWriteQueueTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("PendingWriteQueue")
struct PendingWriteQueueTests {
    private func freshSettings() -> AppSettings {
        let suite = "PendingWriteQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func stubClient(status: Int, body: Data) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, body)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    @Test func enqueueDedupesByArticleAndFieldKind() {
        let settings = freshSettings()
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .read(true)), settings: settings)
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .read(true)), settings: settings)
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .starred(true)), settings: settings)
        #expect(settings.pendingWrites.count == 2)
    }

    @Test func flushRemovesSuccessfulWritesAndKeepsFailedOnes() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            PendingWriteQueue.enqueue(PendingWrite(articleServerID: 100, field: .read(true)), settings: settings)
            PendingWriteQueue.enqueue(PendingWrite(articleServerID: 999, field: .starred(true)), settings: settings)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let ok = request.url!.path == "/api/v1/articles/100"
                let status = ok ? 200 : 404
                let body = ok
                    ? #"{"id":100,"read":true}"#.data(using: .utf8)!
                    : #"{"error":{"code":"not_found","message":"nope"}}"#.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            await PendingWriteQueue.flush(using: ArticleActions(client: client), settings: settings)

            #expect(settings.pendingWrites == [PendingWrite(articleServerID: 999, field: .starred(true))])
        }
    }

    @Test func flushIsANoOpWhenQueueIsEmpty() async throws {
        let settings = freshSettings()
        // No stub configured -- if flush tried to make a request, this would hang/fail.
        await PendingWriteQueue.flush(using: ArticleActions(client: stubClient(status: 200, body: Data())), settings: settings)
        #expect(settings.pendingWrites.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PendingWriteQueueTests`
Expected: FAIL to compile — `PendingWriteQueue`, `PendingWrite`, `PendingWriteField`, `AppSettings.pendingWrites`, and `ArticleActions.setRead` don't exist yet.

- [ ] **Step 3: Implement**

Create `Yana/Services/PendingWriteQueue.swift`:

```swift
import Foundation

/// Which field a queued write targets, and the value it should end up as.
enum PendingWriteField: Codable, Equatable {
    case starred(Bool)
    case read(Bool)

    /// Same-kind check for `PendingWriteQueue.enqueue`'s dedup rule -- ignores the carried value,
    /// since a newer pending write for the same field always supersedes an older one.
    fileprivate var isSameKind: (PendingWriteField) -> Bool {
        { other in
            switch (self, other) {
            case (.starred, .starred), (.read, .read): return true
            default: return false
            }
        }
    }
}

/// One article's not-yet-acknowledged star/read change.
struct PendingWrite: Codable, Equatable {
    let articleServerID: Int
    let field: PendingWriteField
}

/// Replaces the old "roll back the local optimistic write on PATCH failure" pattern for both
/// `starred` and `read`. On failure the change is queued here instead of being reverted, and
/// `SyncEngine.sync()` flushes the queue (retrying each entry) before its normal pull -- so a
/// star/read made while offline is retried opportunistically rather than silently lost. Backed by
/// `AppSettings.pendingWrites` (small, transient, device-local state -- not worth a SwiftData
/// model).
enum PendingWriteQueue {
    /// Enqueues `write`, replacing any existing pending entry for the same
    /// `(articleServerID, field kind)` pair -- a newer pending value for the same field always
    /// wins over an older queued one.
    static func enqueue(_ write: PendingWrite, settings: AppSettings) {
        var pending = settings.pendingWrites
        pending.removeAll { $0.articleServerID == write.articleServerID && $0.field.isSameKind(write.field) }
        pending.append(write)
        settings.pendingWrites = pending
    }

    /// Attempts every pending write's PATCH via `actions`. Entries that succeed are removed;
    /// entries that fail (still offline, or a real server error) stay queued for the next flush.
    static func flush(using actions: ArticleActions, settings: AppSettings) async {
        let pending = settings.pendingWrites
        guard !pending.isEmpty else { return }
        var remaining: [PendingWrite] = []
        for write in pending {
            do {
                switch write.field {
                case .starred(let value):
                    try await actions.setStarred(value, articleServerID: write.articleServerID)
                case .read(let value):
                    try await actions.setRead(value, articleServerID: write.articleServerID)
                }
            } catch {
                remaining.append(write)
            }
        }
        settings.pendingWrites = remaining
    }
}
```

In `Yana/Models/AppSettings.swift`, add a new key to the `Key` enum (near `syncCursor`, line 46):
```swift
static let syncCursor = "settings.syncCursor"
static let pendingWrites = "settings.pendingWrites"
```

Add the property in the `// MARK: Sync` area, after the `syncCursor` property (after line 147):
```swift
/// Not-yet-acknowledged star/read writes, retried opportunistically on the next sync. See
/// `PendingWriteQueue`. Device-local network state -- never synced.
var pendingWrites: [PendingWrite] {
    get {
        access(keyPath: \.pendingWrites)
        guard let data = defaults.data(forKey: Key.pendingWrites),
              let decoded = try? JSONDecoder().decode([PendingWrite].self, from: data) else { return [] }
        return decoded
    }
    set {
        withMutation(keyPath: \.pendingWrites) {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.pendingWrites)
        }
    }
}
```

In `Yana/Services/ArticleActions.swift`, add `ReadBody`/`ReadResponse` next to `StarredBody`/`StarredResponse` (lines 3-4):
```swift
private struct StarredBody: Encodable { let starred: Bool }
private struct StarredResponse: Decodable { let id: Int; let starred: Bool }
private struct ReadBody: Encodable { let read: Bool }
private struct ReadResponse: Decodable { let id: Int; let read: Bool }
```

Add the method after `setStarred` (after line 27):
```swift
func setRead(_ read: Bool, articleServerID: Int) async throws {
    let _: ReadResponse = try await client.patch("/api/v1/articles/\(articleServerID)", body: ReadBody(read: read))
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/PendingWriteQueueTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/PendingWriteQueue.swift Yana/Models/AppSettings.swift Yana/Services/ArticleActions.swift YanaTests/PendingWriteQueueTests.swift
git commit -m "Add PendingWriteQueue, AppSettings.pendingWrites, ArticleActions.setRead"
```

---

### Task 7: `ArticleWrites` facade (toggleStar + markRead), replacing duplicated star-toggle code

**Files:**
- Create: `Yana/Services/ArticleWrites.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (`ReaderScreen.toggleStar`)
- Modify: `Yana/Reader/Mac/TimelineModel.swift` (`toggleStar`)
- Modify: `Yana/Views/Config/ArticleListView.swift` (the leading star swipe action)
- Test: `YanaTests/ArticleWritesTests.swift` (create)

**Interfaces:**
- Consumes: `PendingWriteQueue.enqueue` (Task 6), `ArticleActions.setStarred`/`setRead` (Task 6), `AuthenticatedClient.current()` (existing).
- Produces: `ArticleWrites.toggleStar(_ article: Article, modelContext: ModelContext)`, `ArticleWrites.markRead(_ article: Article, modelContext: ModelContext)`.

This task only *changes* the star call sites' failure handling (enqueue instead of rollback) and *deduplicates* three copies of the same logic into one facade — it does not change their happy-path behavior. `markRead` is new behavior but has no UI wiring yet (that's Task 8) — this task proves it in isolation first.

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/ArticleWritesTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleWrites")
struct ArticleWritesTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func markReadIsANoOpWhenAlreadyRead() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id", url: "https://x.com/1")
        article.setRead(true)
        context.insert(article)
        try context.save()

        ArticleWrites.markRead(article, modelContext: context)
        #expect(article.read == true)   // still true; no crash, no duplicate work observable here
    }

    @Test func markReadSetsReadLocallyWhenNotPaired() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id", url: "https://x.com/1")
        // No serverID set -- matches an article that hasn't been through sync, or a device that
        // isn't paired. `ArticleWrites.markRead` must still flip the local flag.
        context.insert(article)
        try context.save()

        ArticleWrites.markRead(article, modelContext: context)
        #expect(article.read == true)
    }

    @Test func toggleStarFlipsLocallyWhenNotPaired() throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "id", url: "https://x.com/1")
        context.insert(article)
        try context.save()

        ArticleWrites.toggleStar(article, modelContext: context)
        #expect(article.starred == true)
        ArticleWrites.toggleStar(article, modelContext: context)
        #expect(article.starred == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleWritesTests`
Expected: FAIL to compile — `ArticleWrites` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Yana/Services/ArticleWrites.swift`:

```swift
import Foundation
import SwiftData

/// Centralizes the optimistic-local-write-then-PATCH pattern shared by starring and marking read:
/// flip the local flag and save immediately, then fire the PATCH; on failure, enqueue into
/// `PendingWriteQueue` instead of rolling back (see that type's doc comment for why). Silently
/// local-only when not paired -- `AuthenticatedClient.current()` returning `nil` means "nothing to
/// do," not an error, matching every other write path in this app.
@MainActor
enum ArticleWrites {
    static func toggleStar(_ article: Article, modelContext: ModelContext, settings: AppSettings = AppSettings()) {
        let newValue = !article.starred
        article.starred = newValue
        try? modelContext.save()
        guard let client = AuthenticatedClient.current(), let serverID = article.serverID else { return }
        Task {
            do {
                try await ArticleActions(client: client).setStarred(newValue, articleServerID: serverID)
            } catch {
                PendingWriteQueue.enqueue(PendingWrite(articleServerID: serverID, field: .starred(newValue)), settings: settings)
            }
        }
    }

    /// No-ops if already read -- both to avoid a redundant PATCH on every subsequent swipe past an
    /// already-read article, and because a page can be "displayed" more than once in a session
    /// (e.g. swiping back over it).
    static func markRead(_ article: Article, modelContext: ModelContext, settings: AppSettings = AppSettings()) {
        guard !article.read else { return }
        article.setRead(true)
        try? modelContext.save()
        guard let client = AuthenticatedClient.current(), let serverID = article.serverID else { return }
        Task {
            do {
                try await ArticleActions(client: client).setRead(true, articleServerID: serverID)
            } catch {
                PendingWriteQueue.enqueue(PendingWrite(articleServerID: serverID, field: .read(true)), settings: settings)
            }
        }
    }
}
```

Replace `ReaderScreen.toggleStar` in `Yana/Reader/ReaderHostView.swift` (lines 257-275):
```swift
/// Toggles locally right away (optimistic) via `ArticleWrites`; queued for retry rather than
/// rolled back on failure. Silently local-only when not paired.
private func toggleStar(_ article: Article) {
    ArticleWrites.toggleStar(article, modelContext: modelContext)
    Haptics.impact(.light)
}
```

Replace `TimelineModel.toggleStar` in `Yana/Reader/Mac/TimelineModel.swift` (lines 201-219):
```swift
/// Toggles locally right away (optimistic) via `ArticleWrites`; queued for retry rather than
/// rolled back on failure. Silently local-only when not paired.
func toggleStar(_ article: Article) {
    guard let modelContext else { return }
    ArticleWrites.toggleStar(article, modelContext: modelContext)
}
```

Replace the leading star action's body in `Yana/Views/Config/ArticleListView.swift` (lines 90-106):
```swift
Button {
    guard let article = article(for: summary) else { return }
    ArticleWrites.toggleStar(article, modelContext: modelContext)
    Haptics.impact(.light)
} label: {
    Label(summary.isStarred ? "Unstar" : "Star",
          systemImage: summary.isStarred ? "star.slash" : "star")
}
.tint(.yellow)
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleWritesTests`
Expected: PASS

Run the full test suite once to confirm the three call-site replacements didn't regress anything already covered: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS (no test exercised the old inline rollback behavior directly, per the earlier exploration — this is a behavior-preserving-on-the-happy-path refactor).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ArticleWrites.swift Yana/Reader/ReaderHostView.swift Yana/Reader/Mac/TimelineModel.swift Yana/Views/Config/ArticleListView.swift YanaTests/ArticleWritesTests.swift
git commit -m "Add ArticleWrites facade; star/read writes queue-on-failure instead of rolling back"
```

---

### Task 8: Mark-read hooks — iOS pager + list-open + Mac selection

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift`
- Modify: `Yana/Reader/ReaderHostView.swift` (both the `UIViewControllerRepresentable` wiring and `ReaderScreen.openArticle`)
- Modify: `Yana/Reader/Mac/TimelineModel.swift` (`selection` setter + `moveSelection`)
- Modify: `YanaTests/TimelineModelTests.swift`

**Interfaces:**
- Consumes: `ArticleWrites.markRead` (Task 7).
- Produces: `ReaderArticleViewController.onArticleDisplayed: ((Article) -> Void)?`.

- [ ] **Step 1: Write the failing test (Mac side — the only side unit-testable without a UIKit harness)**

Add to `YanaTests/TimelineModelTests.swift` (using its existing `makeConfiguredModel` helper):

```swift
@Test func settingSelectionMarksTheNewArticleRead() async throws {
    let settings = freshSettings()
    let (model, store) = try makeConfiguredModel(settings: settings)
    await store.refreshNow()
    model.applyTimeline()   // parks on "a" per the helper's 3-article a/b/c fixture

    model.selection = "b"
    let article = model.resolve(model.selectedSummary!)
    #expect(article?.read == true)
}

@Test func moveSelectionMarksTheNewArticleRead() async throws {
    let settings = freshSettings()
    let (model, store) = try makeConfiguredModel(settings: settings)
    await store.refreshNow()
    model.applyTimeline()
    model.currentIndex = 0

    model.moveSelection(by: 1)
    let article = model.resolve(model.selectedSummary!)
    #expect(article?.read == true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineModelTests`
Expected: FAIL — `selection`/`moveSelection` don't mark anything read yet.

- [ ] **Step 3: Implement**

In `Yana/Reader/Mac/TimelineModel.swift`, `selection`'s setter (lines 79-92) — add the mark-read call right after `currentIndex = i`:
```swift
set {
    guard let id = newValue,
          let i = TimelinePageIndex.index(of: id, in: filteredArticles),
          i != currentIndex
    else { return }
    currentIndex = i
    anchorWriter.record(filteredArticles[i])
    if let modelContext, let article = resolve(filteredArticles[i]) {
        ArticleWrites.markRead(article, modelContext: modelContext)
    }
}
```

`moveSelection(by:)` (lines 112-119) — add the same call after `anchorWriter.record`:
```swift
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
```

In `Yana/Reader/ReaderArticleViewController.swift`, add the new callback property next to `onIndexChange` (line 30):
```swift
var onIndexChange: ((Int) -> Void)?
var onArticleDisplayed: ((Article) -> Void)?
```

Fire it in `pageViewController(didFinishAnimating:...)` (lines 709-727), right after `onIndexChange?(i)`:
```swift
index = i
recordWiredNeighbors()
updateStarItem()
onIndexChange?(i)
onArticleDisplayed?(vc.article)
prewarmNeighbors(around: i)
```

In `Yana/Reader/ReaderHostView.swift`, wire the new callback through the `UIViewControllerRepresentable`. Add a property (after `onUserNavigate`, line 16):
```swift
var onUserNavigate: ((Int) -> Void)?
var onArticleDisplayed: ((Article) -> Void)?
```

Set it in both `makeUIViewController` (after line 39) and `updateUIViewController` (after line 64):
```swift
reader.onIndexChange = { i in currentIndex = i; onUserNavigate?(i) }
reader.onArticleDisplayed = onArticleDisplayed
```

In `ReaderScreen.body`, pass it into the `ReaderHostView(...)` call (after `onUserNavigate: { saveAnchor(at: $0) },`, line 184):
```swift
onUserNavigate: { saveAnchor(at: $0) },
onArticleDisplayed: { markRead($0) },
```

Add the `markRead` method next to `toggleStar` in `ReaderScreen` (after the `toggleStar` replacement from Task 7):
```swift
private func markRead(_ article: Article) {
    ArticleWrites.markRead(article, modelContext: modelContext)
}
```

Update `ReaderScreen.openArticle` (lines 283-290) to also mark read on list-open:
```swift
private func openArticle(_ summary: ArticleSummary) {
    recomputeFilter()
    if let i = TimelinePageIndex.index(of: summary.identifier, in: filteredArticles) {
        appState.currentIndex = i
        anchorController.recordOpenedArticle(summary)
        if let article = ArticleResolution.resolve(summary, in: modelContext) {
            markRead(article)
        }
    }
    appState.showArticleList = false
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineModelTests`
Expected: PASS

- [ ] **Step 5: Manual verification (iOS pager path has no unit-test harness)**

Run the app in the iOS Simulator (`xcodebuild ... build` then launch, or via Xcode), pair or use the DEBUG seed, and confirm: swiping to a new article in the reader flips it out of the unread block on the next reader-list open; opening an article directly from the article list does the same.

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/ReaderArticleViewController.swift Yana/Reader/ReaderHostView.swift Yana/Reader/Mac/TimelineModel.swift YanaTests/TimelineModelTests.swift
git commit -m "Mark articles read on swipe/select/open"
```

---

### Task 9: `SyncEngine` flushes the pending-write queue before pulling

**Files:**
- Modify: `Yana/Services/SyncEngine.swift`
- Modify: `YanaTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `PendingWriteQueue.flush` (Task 6).
- Produces: nothing new — behavior change inside `performSync()`.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/SyncEngineTests.swift`:

```swift
@Test func syncFlushesPendingWritesBeforePulling() async throws {
    try await MockURLProtocol.lock.withLock {
        let container = try makeContainer()
        let defaults = UserDefaults(suiteName: "SyncEngineTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.pendingWrites = [PendingWrite(articleServerID: 100, field: .read(true))]

        var sawPatch = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            if request.httpMethod == "PATCH", request.url!.path == "/api/v1/articles/100" {
                sawPatch = true
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                        #"{"id":100,"read":true}"#.data(using: .utf8)!)
            }
            let responses: [String: (Data, Int)] = [
                "/api/v1/articles/sync": (#"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!, 200),
                "/api/v1/feeds": (#"{"feeds":[]}"#.data(using: .utf8)!, 200),
                "/api/v1/tags": (#"{"tags":[]}"#.data(using: .utf8)!, 200),
            ]
            let (data, status) = responses[request.url!.path] ?? (Data(), 404)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
        }
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

        let engine = SyncEngine(container: container, client: client, settings: settings)
        _ = try await engine.sync()

        #expect(sawPatch)
        #expect(settings.pendingWrites.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncEngineTests/syncFlushesPendingWritesBeforePulling`
Expected: FAIL — `sawPatch` stays `false`, `settings.pendingWrites` stays populated.

- [ ] **Step 3: Implement**

In `Yana/Services/SyncEngine.swift`, `performSync()` (starting at line 74), add the flush as the very first line:
```swift
private func performSync() async throws -> SyncResult {
    await PendingWriteQueue.flush(using: ArticleActions(client: client), settings: settings)

    var totalNew = 0, totalUpdated = 0, totalRemoved = 0
    var resyncAttempts = 0
    ...
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SyncEngineTests`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/SyncEngine.swift YanaTests/SyncEngineTests.swift
git commit -m "SyncEngine flushes pending star/read writes before pulling"
```

---

### Task 10: Unread indicator dot in `ArticleListView`

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift`

**Interfaces:**
- Consumes: `ArticleSummary.isRead` (Task 2).
- Produces: nothing new — visual-only change to the existing `row(_:)` view builder.

- [ ] **Step 1: Manual visual check first (no meaningful unit test for a SwiftUI view's rendered output in this codebase's existing style — every other row-rendering change here, e.g. the `isCurrent` checkmark, has no dedicated test either)**

Note the current row layout (`row(_:)`, lines 222-253) so the diff below is additive only.

- [ ] **Step 2: Implement**

In `Yana/Views/Config/ArticleListView.swift`, `row(_:)` (lines 222-253), add a small dot before the title:
```swift
private func row(_ summary: ArticleSummary) -> some View {
    let isCurrent = summary.identifier == currentArticleID
    return HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 2)
            .fill(isCurrent ? Color.accentColor : Color.clear)
            .frame(width: 3)
        FeedLogoView(hash: summary.feedLogoHash)
        VStack(alignment: .leading, spacing: rowLineSpacing) {
            HStack(spacing: 6) {
                if !summary.isRead {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(Text("Unread"))
                }
                Text(summary.title).font(.headline).lineLimit(2)
            }
            HStack(spacing: 6) {
                if !summary.feedName.isEmpty {
                    Text(summary.feedName)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(summary.createdAt, style: .date)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        if isCurrent {
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("Current article"))
        }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
}
```

Add the new accessibility string to `Yana/Resources/Localizable.xcstrings`: key `"Unread"`, English `"Unread"`, German `"Ungelesen"`, both marked `"state": "translated"` (follow the exact JSON shape of an existing single-word entry like `"Cancel"` in that file).

- [ ] **Step 3: Build and manually verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: succeeds. Then run the app, open the article list, and confirm unread articles show the dot and read ones don't.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift Yana/Resources/Localizable.xcstrings
git commit -m "Show an unread indicator dot in the article list"
```

---

### Task 11: `AppSettings.showUnreadBadge` + `NotificationsSettingsSection` toggle

**Files:**
- Modify: `Yana/Models/AppSettings.swift`
- Modify: `Yana/Views/Config/Settings/NotificationsSettingsSection.swift`
- Test: `YanaTests/AppSettingsTests.swift` (check first with `find YanaTests -iname 'AppSettingsTests.swift'`; if absent, create it — if present, add to it)

**Interfaces:**
- Consumes: nothing new.
- Produces: `AppSettings.showUnreadBadge: Bool` (default `false`).

- [ ] **Step 1: Write the failing test**

If `YanaTests/AppSettingsTests.swift` doesn't exist, create it with this content; otherwise add the one `@Test` function to the existing suite (matching its existing `freshSettings()`-style helper if one exists):

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {
    private func freshSettings() -> AppSettings {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    @Test func showUnreadBadgeDefaultsToFalse() {
        #expect(freshSettings().showUnreadBadge == false)
    }

    @Test func showUnreadBadgeRoundTrips() {
        let settings = freshSettings()
        settings.showUnreadBadge = true
        #expect(settings.showUnreadBadge == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsTests`
Expected: FAIL to compile — no member `showUnreadBadge`.

- [ ] **Step 3: Implement**

In `Yana/Models/AppSettings.swift`, add a key (near `notificationsEnabled`, line 41):
```swift
static let notificationsEnabled = "settings.notificationsEnabled"
static let showUnreadBadge = "settings.showUnreadBadge"
```

Add the property right after `notificationsEnabled` (after line 119):
```swift
var notificationsEnabled: Bool {
    get { access(keyPath: \.notificationsEnabled); return defaults.bool(forKey: Key.notificationsEnabled) }
    set { withMutation(keyPath: \.notificationsEnabled) { defaults.set(newValue, forKey: Key.notificationsEnabled) } }
}
/// Opt-in (default off) app-icon badge showing the unread count within the current timeline
/// filter. See `UnreadBadgeUpdater`.
var showUnreadBadge: Bool {
    get { access(keyPath: \.showUnreadBadge); return defaults.bool(forKey: Key.showUnreadBadge) }
    set { withMutation(keyPath: \.showUnreadBadge) { defaults.set(newValue, forKey: Key.showUnreadBadge) } }
}
```

In `Yana/Views/Config/Settings/NotificationsSettingsSection.swift`, add a second toggle to the `Section` (after the existing `Toggle`, before line 27's closing):
```swift
Section("Notifications") {
    Toggle(isOn: Binding(
        get: { settings.notificationsEnabled },
        set: { newValue in
            if newValue {
                Task {
                    let granted = await NotificationService().requestAuthorization()
                    settings.notificationsEnabled = granted
                    if !granted { showNotificationDeniedAlert = true }
                }
            } else {
                settings.notificationsEnabled = false
            }
        }
    )) {
        Label("Notify about new articles", systemImage: "bell.badge.fill")
            .labelStyle(.tintedIcon(.red))
    }
    Toggle(isOn: $settings.showUnreadBadge) {
        Label("Show unread count on app icon", systemImage: "app.badge")
            .labelStyle(.tintedIcon(.red))
    }
}
```

Add `"Show unread count on app icon"` to `Yana/Resources/Localizable.xcstrings`: English `"Show unread count on app icon"`, German `"Ungelesene Anzahl auf App-Symbol anzeigen"`, both `"state": "translated"`.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/Views/Config/Settings/NotificationsSettingsSection.swift Yana/Resources/Localizable.xcstrings YanaTests/AppSettingsTests.swift
git commit -m "Add showUnreadBadge setting and its Notifications-section toggle"
```

---

### Task 12: `UnreadBadgeUpdater`, hooked into `ArticleStore.publish(_:)`

**Files:**
- Create: `Yana/Services/UnreadBadgeUpdater.swift`
- Modify: `Yana/Services/ArticleStore.swift` (`publish(_:)`)
- Test: `YanaTests/UnreadBadgeUpdaterTests.swift` (create)

**Interfaces:**
- Consumes: `AppSettings.showUnreadBadge` (Task 11), `TagFilter`/`FeedFilter`/`StarredFilter` (existing), `ArticleSummary.isRead` (Task 2).
- Produces: `UnreadBadgeUpdater.count(from:settings:) -> Int` (the pure, testable part) and `UnreadBadgeUpdater.refresh(summaries:settings:)` (the side-effecting part that also sets the system badge, called from `ArticleStore.publish(_:)`).

Splitting the pure count function out from the `UNUserNotificationCenter` side effect keeps the actual badge-count logic unit-testable without touching notification permissions in tests.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/UnreadBadgeUpdaterTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("UnreadBadgeUpdater")
struct UnreadBadgeUpdaterTests {
    private func freshSettings() -> AppSettings {
        let suite = "UnreadBadgeUpdaterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makeSummary(
        identifier: String, feedName: String = "", tagNames: Set<String> = [],
        isStarred: Bool = false, isRead: Bool = false
    ) throws -> ArticleSummary {
        let container = try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let feed = Feed(name: feedName, aggregator: "feedContent", identifier: identifier + "-feed")
        context.insert(feed)
        let article = Article(title: identifier, identifier: identifier, url: "https://x.com/\(identifier)")
        article.feed = feed
        article.starred = isStarred
        article.setRead(isRead)
        context.insert(article)
        try context.save()
        return ArticleSummary(article)
    }

    @Test func countsOnlyUnreadWithNoFilter() throws {
        let settings = freshSettings()
        let summaries = [
            try makeSummary(identifier: "a", isRead: false),
            try makeSummary(identifier: "b", isRead: true),
            try makeSummary(identifier: "c", isRead: false),
        ]
        #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 2)
    }

    @Test func respectsStarredOnlyFilter() throws {
        let settings = freshSettings()
        settings.starredOnly = true
        let summaries = [
            try makeSummary(identifier: "a", isStarred: true, isRead: false),
            try makeSummary(identifier: "b", isStarred: false, isRead: false),
        ]
        #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 1)
    }

    @Test func respectsDisabledFeedNamesFilter() throws {
        let settings = freshSettings()
        settings.disabledFeedNames = ["Muted"]
        let summaries = [
            try makeSummary(identifier: "a", feedName: "Muted", isRead: false),
            try makeSummary(identifier: "b", feedName: "Kept", isRead: false),
        ]
        #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UnreadBadgeUpdaterTests`
Expected: FAIL to compile — `UnreadBadgeUpdater` doesn't exist.

- [ ] **Step 3: Implement**

Create `Yana/Services/UnreadBadgeUpdater.swift`:

```swift
import Foundation
#if canImport(UIKit)
import UserNotifications
#endif

/// Opt-in app-icon badge showing the unread count *within the user's current timeline filter*
/// (tag/feed/starred-only selections), not the full library. Hooked into
/// `ArticleStore.publish(_:)` so it recomputes on every sync pull and every local star/read write —
/// the same single choke point that already drives everything else keyed off the article index.
@MainActor
enum UnreadBadgeUpdater {
    /// The pure count: applies the same `TimelineFiltering` pipeline the on-screen list uses, then
    /// counts unread among the result. Split out from `refresh` so it's testable without touching
    /// `UNUserNotificationCenter`.
    static func count(from summaries: [ArticleSummary], settings: AppSettings) -> Int {
        let byTag = TagFilter.apply(
            to: summaries, disabledTagNames: settings.disabledTagNames, includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let filtered = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        return filtered.filter { !$0.isRead }.count
    }

    /// Recomputes and pushes the system badge, or clears it when the setting is off.
    static func refresh(summaries: [ArticleSummary], settings: AppSettings = AppSettings()) {
        #if canImport(UIKit)
        guard settings.showUnreadBadge else {
            UNUserNotificationCenter.current().setBadgeCount(0)
            return
        }
        UNUserNotificationCenter.current().setBadgeCount(count(from: summaries, settings: settings))
        #endif
    }
}
```

In `Yana/Services/ArticleStore.swift`, `publish(_:)` (lines 311-315), call it after assigning `summaries`:
```swift
private func publish(_ next: [ArticleSummary]) {
    guard next != summaries else { return }
    summaries = next
    UnreadBadgeUpdater.refresh(summaries: next)
    cacheCoalescer?.schedule()
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UnreadBadgeUpdaterTests`
Expected: PASS

- [ ] **Step 5: Manual verification**

Run the app, enable "Show unread count on app icon" in Settings, background the app, and confirm the badge appears with the correct count; disable the setting and confirm it clears.

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/UnreadBadgeUpdater.swift Yana/Services/ArticleStore.swift YanaTests/UnreadBadgeUpdaterTests.swift
git commit -m "Add opt-in app-icon unread badge, filter-aware"
```

---

### Task 13: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** None — documentation only.

- [ ] **Step 1: Update the "No read/unread state" bullet**

In `CLAUDE.md`'s **Key patterns** section, find the bullet starting `**No read/unread state:**` and replace it with a description of the new behavior:

```markdown
- **Read state drives the primary sort:** the timeline sorts by `Article.readRank` (0=read,
  1=unread) then `Article.createdAt` — read articles first (oldest→newest), then unread articles
  (oldest→newest), so the next unvisited article is always the boundary between the two blocks.
  An article is marked read automatically the moment it becomes the current/displayed one: an iOS
  pager swipe completing, opening it from the article list, or a Mac sidebar selection change
  (`ArticleWrites.markRead`). The server can upgrade a synced article from unread to read (read
  on another device) but a sync pass can never downgrade an already-locally-read article back to
  unread (`SyncWriter.upsertSummaries`'s upgrade-only rule) — this prevents a racing sync from
  reordering the list under the user's finger. Starring remains a separate, orthogonal
  `Article.starred` boolean with its own "Starred Only" quick-filter, unaffected by read state.
```

- [ ] **Step 2: Update the Models/Sync/Actions architecture bullets**

In the **Models** bullet, add `read`/`readRank` to the list of `Article` fields it documents (alongside `starred`/`hasContent`), briefly noting the "never assign directly, use `setRead(_:)`" rule.

In the **Sync** bullet, add one sentence noting `SyncWriter.upsertSummaries` also applies `read` (upgrade-only on update, unconditional on insert), and that `SyncEngine.sync()` now flushes `PendingWriteQueue` before its normal pull.

In the **Actions** bullet, replace the sentence "Starring is optimistic — the reader/list flip `Article.starred` locally and save immediately, then fire `setStarred` and roll back only on failure" with:

```markdown
Starring and marking read are both optimistic, funneled through the shared `ArticleWrites`
facade — flip the local flag and save immediately, then fire the PATCH; on failure the change is
enqueued into `PendingWriteQueue` (backed by `AppSettings.pendingWrites`) instead of being rolled
back, and `SyncEngine.sync()` retries every queued write opportunistically before its normal pull.
Both stay silently local-only when not paired.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document read-state sort, mark-read, and the pending-write queue"
```

---

## Post-plan check

After Task 13, run the full suite once more and confirm the app builds and boots in the simulator with the DEBUG seed, since no single task exercises the full swipe→mark-read→resort loop end-to-end:

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```
