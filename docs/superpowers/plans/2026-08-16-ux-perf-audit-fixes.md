# UX & Performance Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every confirmed finding of the 2026-08-16 UX & performance audit: ten performance defects (P1–P10), sixteen UX defects (U1–U16), and the doc/test drift found in passing.

**Architecture:** No new subsystems. Each task is a localized fix inside the existing sync/store/reader/Mac structure, grouped by root cause: a cached Keychain token kills the per-row XPC storm; a prune gate kills the every-sync full-body decode; pure-function seams (`DevicePairing.classify`, `InitialSyncGate.run(syncOnce:)`, `RefreshOutcome.message`) make the UX fixes unit-testable.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + SwiftData, Swift Testing (`import Testing`) in `YanaTests/`, XCTest in `YanaUITests/`, xcstrings catalog.

**Spec:** The audit findings list (P1–P10, U1–U16, drift) as posted in the conversation of 2026-08-16; the finding IDs below refer to it. There is no separate spec file — each task restates its finding inline.

## Global Constraints

- Swift 6 strict concurrency; `@MainActor` annotations throughout; every `@MainActor` → `@ModelActor` call goes through `OffMainActor.run` (CLAUDE.md "Key patterns").
- Platform: iOS 26.0+ (iPhone, iPad, Mac Catalyst). Mac-only code is `#if targetEnvironment(macCatalyst)`.
- **Every new or changed user-facing string gets a `Localizable.xcstrings` entry with a `de` translation marked `"state" : "translated"`.** German: Apple style, infinitive, no Du/Sie.
- **User-facing copy is prose: no bullet lists, no em/en dashes as clause glue** (CLAUDE.md "User-facing text style").
- Count-bearing strings need explicit `en` AND `de` plural blocks (`variations.plural.{one,other}`); never rely on key fallback.
- Timeline order is `TimelineOrder` (`createdAt` asc, `serverID` tiebreak); nothing in this plan may reorder it. Filters only remove rows.
- Test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test` (narrow with `-only-testing:YanaTests`). Build-only check: same command with `build`.
- Do not run two `xcodebuild` invocations concurrently. If the test runner fails with a Mach -308 error, shut down simulators and retry once.
- Commit style: short imperative sentences, no conventional-commit prefixes (match `git log`).

## Deliberately NOT in this plan

- **Reader text-run `NSAttributedString` memoization** (reader-perf finding 8): the lazy-VStack rebuild is a documented memory trade (`ArticleBlockView.swift:81-86`), and any cheap cache key (plain text) can collide across differently-styled runs and render wrong markup. Revisit only with a profiler trace showing it dominates.
- **`LibraryChangeSet` Set-backed rewrite** (P10c): Task 11's coalescer max-delay ceiling bounds burst size, which bounds the quadratic; the rewrite would ripple through `SummaryIndexMerge` for little residual gain.
- **`ImageStore` response streaming**: `YanaAPIClient.getRaw` buffers whole responses by design; Task 5's concurrency bound caps peak memory instead.
- **`ImageStore` actor → lock-protected class conversion** (data-audit finding 8, reader IO queuing behind sync's disk writes): Task 9 removes the reader's hottest `ImageStore` dependency (logos go through `ReaderImageCache`, whose decoded cache already avoids the actor on every hit), which shrinks the contention window to cold-miss byte reads during an active sync. Convert the actor only if pop-in is still visible after that.

---

### Task 1: Cache the device token behind the Keychain (P1 root cause)

`AuthenticatedClient.current()` does a synchronous `SecItemCopyMatching` XPC round trip on every call, and it is called per list row, per Mac sidebar row, and 3× per `ReaderScreen` body pass. Cache the token in `KeychainService` with explicit invalidation on save/delete. The cache must be thread-safe: `deleteDeviceToken()` is called off-main from `SyncEngine.backfillMissingContent`'s `@Sendable` closure (`SyncEngine.swift:258`).

**Files:**
- Modify: `Yana/Services/KeychainService.swift`
- Test: `YanaTests/KeychainServiceTests.swift`

**Interfaces:**
- Produces: `KeychainService.loadDeviceToken()` — same signature, now served from an in-process cache after the first hit. `saveDeviceToken`/`deleteDeviceToken` update the cache. No caller changes anywhere.

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/KeychainServiceTests.swift` (create the suite if the file only has other suites; follow the existing `@MainActor`/`import Testing` style):

```swift
@Test func deviceTokenCacheTracksSaveAndDelete() {
    KeychainService.deleteDeviceToken()
    #expect(KeychainService.loadDeviceToken() == nil)
    KeychainService.saveDeviceToken("token-a")
    #expect(KeychainService.loadDeviceToken() == "token-a")
    #expect(KeychainService.loadDeviceToken() == "token-a")   // second read: cache path
    KeychainService.saveDeviceToken("token-b")
    #expect(KeychainService.loadDeviceToken() == "token-b")
    KeychainService.deleteDeviceToken()
    #expect(KeychainService.loadDeviceToken() == nil)
}
```

- [ ] **Step 2: Run to verify current behavior** — `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/KeychainServiceTests`. This test may already PASS (it pins behavior, not the XPC count); that is fine — it guards the refactor.

- [ ] **Step 3: Implement the cache**

In `Yana/Services/KeychainService.swift`, add at the top of the enum:

```swift
import os

/// One-slot cache for the device token. `.none` = not yet read from Keychain;
/// `.some(nil)` = read and absent; `.some(.some(t))` = read and present.
/// Lock-protected because `deleteDeviceToken` is called off-main from
/// `SyncEngine.backfillMissingContent`'s bounded task group.
private static let deviceTokenCache = OSAllocatedUnfairLock<String??>(initialState: nil)
```

Change the three device-token functions (keep `save`/`load`/`delete(key:)` untouched — they are generic):

```swift
@discardableResult
static func saveDeviceToken(_ token: String) -> Bool {
    let ok = save(key: deviceTokenKey, value: token)
    if ok { deviceTokenCache.withLock { $0 = .some(token) } }
    return ok
}

static func loadDeviceToken() -> String? {
    if let cached = deviceTokenCache.withLock({ $0 }) { return cached }
    let loaded = load(key: deviceTokenKey)
    deviceTokenCache.withLock { $0 = .some(loaded) }
    return loaded
}

@discardableResult
static func deleteDeviceToken() -> Bool {
    let ok = delete(key: deviceTokenKey)
    deviceTokenCache.withLock { $0 = .some(nil) }
    return ok
}
```

Note: `UITestReset` and `ScreenshotSeed` already go through these three functions (verified by grep), so the cache can never go stale from inside the app. Document that any future direct `save(key:)` write of the device-token key must invalidate the cache.

- [ ] **Step 4: Run the test again** — expect PASS. Also run the full `YanaTests` bundle once (`-only-testing:YanaTests`) since pairing/auth suites touch the token.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Cache the device token so AuthenticatedClient stops paying a Keychain XPC per call"`

---

### Task 2: Hoist per-row `AuthenticatedClient`/resolve work out of view builders (P1 call sites, reader-perf findings 3, 4, 6)

Even cached, `AuthenticatedClient.current()` constructs an `AppSettings()` per call, and the Mac row context menu additionally does a SwiftData fetch (`model.resolve(summary)`) at **row-body** time, not click time.

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift:83`
- Modify: `Yana/Reader/Mac/MacRootView.swift:572-620` (`MacArticleRow.contextMenuItems`)

**Interfaces:**
- Consumes: Task 1's cached token (makes remaining calls cheap but not free).
- Produces: no API changes; `MacArticleRow` context-menu buttons resolve the `Article` inside their action closures.

- [ ] **Step 1: ArticleListView — one pairing check per body**

In `ArticleListView.body` (line 58), alongside `let results = results`, add `let isPaired = AuthenticatedClient.current() != nil`, and change line 83 from `if AuthenticatedClient.current() != nil {` to `if isPaired {`. (The inner `AuthenticatedClient.current()` at line 86 runs only on tap — leave it.)

- [ ] **Step 2: MacArticleRow — resolve on click, not on row realization**

Replace the head of `contextMenuItems` (`MacRootView.swift:572-577`). Delete the eager `let article = model.resolve(summary)` and `let config = ReaderMenuBuilder.config(...)`; gate items on the cheap summary-level facts instead and resolve inside each action:

```swift
@ViewBuilder private var contextMenuItems: some View {
    // Resolved lazily inside each action: `contextMenu` evaluates this builder at ROW-BODY
    // time for every visible row, so a SwiftData fetch or Keychain read here is paid per
    // scrolled row, not per right-click (audit finding).
    let hasServer = model.hasServer

    Button {
        if let article = model.resolve(summary) { model.toggleStar(article) }
    } label: {
        Label(summary.isStarred ? "Unstar" : "Star",
              systemImage: summary.isStarred ? "star.slash" : "star")
    }

    if hasServer {
        Button {
            if let article = model.resolve(summary) { model.openWebsite(article) }
        } label: { Label("Open in Browser", systemImage: "safari") }
        Button {
            if let article = model.resolve(summary) { model.copyLink(article) }
        } label: { Label("Copy link", systemImage: "link") }
        Button {
            if let article = model.resolve(summary) { model.openOnServer(article) }
        } label: { Label("Open on Server", systemImage: "server.rack") }
        Divider()
        Button {
            if let article = model.resolve(summary) { model.forceUpdateArticle(article) }
        } label: { Label("Reload", systemImage: "arrow.trianglehead.2.clockwise") }
    } else {
        Button {
            if let article = model.resolve(summary) { model.copyLink(article) }
        } label: { Label("Copy link", systemImage: "link") }
    }

    if model.aiReady {
        Button {
            if let article = model.resolve(summary) { model.summarize(article) }
        } label: { Label("Summarize", systemImage: "sparkles") }
            .disabled(model.isSummarizing)
    }
}
```

Behavior notes to preserve: `ReaderMenuBuilder.config` gated Copy link on `hasURL` and Open-on-Server on `serverID != nil`; a summary always has an identifier-URL and synced articles always have a `serverID`, and the actions no-op safely when not (`model.openOnServer` re-checks `serverID`), so summary-level gating is equivalent for real data. `model.hasServer` and `model.aiReady` still call `AuthenticatedClient.current()` once each per row body — cheap after Task 1.

- [ ] **Step 3: Build** — `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`. Expected: succeeds.

- [ ] **Step 4: Commit** — `git commit -am "Stop resolving articles and pairing state per row in list and sidebar builders"`

---

### Task 3: Gate `pruneOrphanedImages` so syncs stop decoding every article body (P2)

`SyncWriter.referencedImageHashes()` (`SyncWriter.swift:250-263`) fetches every `Article` and JSON-decodes every body on **every** sync pass, via `SyncEngine.pruneOrphanedImages` (`SyncEngine.swift:271-278`). Run the prune only when something could actually have been orphaned: server removals, feed prunes, or a local swipe-to-delete.

**Files:**
- Modify: `Yana/Services/SyncWriter.swift` (`applyRemovals` returns count; `replaceFeeds` reports prunes)
- Modify: `Yana/Services/SyncEngine.swift` (`performSync` gates the prune)
- Modify: `Yana/Models/AppSettings.swift` (new `imagePruneNeeded` flag)
- Modify: `Yana/Views/Config/ArticleListView.swift` (delete path sets the flag)
- Test: `YanaTests/SyncWriterTests.swift`

**Interfaces:**
- Produces: `SyncWriter.applyRemovals(_ serverIDs: [Int]) -> Int` (count actually deleted); `SyncWriter.replaceFeeds(_ feeds: [SyncFeedWire]) -> (touched: [PersistentIdentifier], prunedFeeds: Int)`; `AppSettings.imagePruneNeeded: Bool` (UserDefaults-backed, default `false`).
- Consumers to update: `SyncEngine.performSync`/`syncFeeds` (this task), plus any `SyncWriterTests` calls to the old signatures.

- [ ] **Step 1: Write the failing tests**

In `YanaTests/SyncWriterTests.swift`, following the suite's existing throwaway-container setup:

```swift
@Test func applyRemovalsReturnsDeletedCount() async throws {
    // seed two articles with serverIDs 1 and 2 via upsertSummaries (reuse the suite's wire fixture helper)
    let deleted = await writer.applyRemovals([1, 99])   // 99 doesn't exist locally
    #expect(deleted == 1)
}

@Test func replaceFeedsReportsPrunedFeeds() async throws {
    _ = await writer.replaceFeeds([feedWire(id: 1), feedWire(id: 2)])
    let second = await writer.replaceFeeds([feedWire(id: 1)])
    #expect(second.prunedFeeds == 1)
}
```

- [ ] **Step 2: Run to verify they fail** — compile error (`applyRemovals` returns Void; `replaceFeeds` returns an array). That counts as the failing state.

- [ ] **Step 3: Implement the writer changes**

`applyRemovals` (`SyncWriter.swift:133-142`):

```swift
@discardableResult
func applyRemovals(_ serverIDs: [Int]) -> Int {
    guard !serverIDs.isEmpty else { return 0 }
    var deleted = 0
    for id in serverIDs {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == id })
        descriptor.fetchLimit = 1
        if let article = try? modelContext.fetch(descriptor).first {
            modelContext.delete(article)
            deleted += 1
        }
    }
    try? modelContext.save()
    return deleted
}
```

(Keep the existing one-id-at-a-time doc comment — the `TERNARY` trap still applies.)

`replaceFeeds`: change `pruneMissing` to return the pruned count —

```swift
@discardableResult
private func pruneMissing<Model: PersistentModel>(
    _ descriptor: FetchDescriptor<Model>, shouldPrune: (Model) -> Bool
) -> Int {
    guard let existing = try? modelContext.fetch(descriptor) else { return 0 }
    var pruned = 0
    for model in existing where shouldPrune(model) {
        modelContext.delete(model)
        pruned += 1
    }
    return pruned
}
```

— and change `replaceFeeds`'s tail to capture and return it:

```swift
let prunedFeeds = pruneMissing(FetchDescriptor<Feed>()) { !seenIdentifiers.contains($0.identifier) }
try? modelContext.save()
return (touched, prunedFeeds)
```

with signature `func replaceFeeds(_ feeds: [SyncFeedWire]) -> (touched: [PersistentIdentifier], prunedFeeds: Int)`. `syncTags`'s `pruneMissing` call keeps discarding the result (`_ =` or `@discardableResult` covers it).

- [ ] **Step 4: Add the settings flag**

In `Yana/Models/AppSettings.swift`, add `imagePruneNeeded: Bool` following the exact pattern of an existing UserDefaults-backed Bool (e.g. `hasCompletedInitialSync`): same property style, default `false`, registered alongside the others if the class registers defaults.

- [ ] **Step 5: Gate the prune in `SyncEngine.performSync`**

`syncFeeds()` returns the pruned count: change its signature to `private func syncFeeds() async throws -> Int` and its writer call to

```swift
let result = await OffMainActor.run { await writer.replaceFeeds(response.feeds) }
// ... logo fetch loop unchanged ...
return result.prunedFeeds
```

In `performSync()` (`SyncEngine.swift:102-167`): capture `let prunedFeeds = try await syncFeeds()`; accumulate real deletions by changing the page loop's removal line to `totalRemoved += await OffMainActor.run { await writer.applyRemovals(removed) }` (note: `totalRemoved` currently counts the *listed* ids at line 144 — keep reporting `removed.count` in `SyncResult` totals exactly as before by tracking a separate `actuallyDeleted` counter for the gate, so the user-facing counts don't change). Then replace the unconditional prune at line 164:

```swift
try await backfillMissingContent()
// Pruning requires decoding every local article body (see SyncWriter.referencedImageHashes),
// so it runs only when this pass could actually have orphaned something: a server-side
// removal landed, a feed disappeared, or a local swipe-to-delete flagged it since last time.
if actuallyDeleted > 0 || prunedFeeds > 0 || settings.imagePruneNeeded {
    await pruneOrphanedImages()
    settings.imagePruneNeeded = false
}
```

- [ ] **Step 6: Flag local deletes**

In `ArticleListView`'s delete-confirm action (`ArticleListView.swift:158-164`), after `try? modelContext.save()`, add `settings.imagePruneNeeded = true`.

- [ ] **Step 7: Run tests** — `-only-testing:YanaTests/SyncWriterTests -only-testing:YanaTests/SyncEngineTests`. Fix any test still calling the old signatures. Expected: PASS.

- [ ] **Step 8: Commit** — `git commit -am "Prune orphaned images only when a removal happened instead of decoding every body per sync"`

---

### Task 4: Take the reload path's title re-fetch off the main actor (P3)

`UpdateAndSync.fetchAndApplyContent` (`UpdateAndSync.swift:169`) constructs a `ModelContext(container)` and fetches **on the main actor** — the one unwrapped main-thread SwiftData access left (the file's own rule is at lines 146-152).

**Files:**
- Modify: `Yana/Services/UpdateAndSync.swift:168-174`
- Modify: `Yana/Services/SyncWriter.swift` (new `articleTitle(serverID:)`)
- Test: `YanaTests/SyncWriterTests.swift`

**Interfaces:**
- Produces: `SyncWriter.articleTitle(serverID: Int) -> String?`.

- [ ] **Step 1: Failing test**

```swift
@Test func articleTitleFetchesByServerID() async throws {
    // seed one article with serverID 7, title "Hello" via upsertSummaries
    #expect(await writer.articleTitle(serverID: 7) == "Hello")
    #expect(await writer.articleTitle(serverID: 8) == nil)
}
```

- [ ] **Step 2: Run — fails to compile** (method missing).

- [ ] **Step 3: Implement**

In `SyncWriter`:

```swift
/// The current title for a synced article, for the reload path's post-sync title refresh --
/// keeps that read on this actor (hopped off-main by the caller via OffMainActor.run) instead
/// of a main-actor ModelContext fetch.
func articleTitle(serverID: Int) -> String? {
    var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == serverID })
    descriptor.fetchLimit = 1
    descriptor.propertiesToFetch = [\.title]
    return try? modelContext.fetch(descriptor).first?.title
}
```

In `UpdateAndSync.fetchAndApplyContent`, replace lines 168-174 with:

```swift
if let visibleArticle, visibleArticle.serverID == articleServerID {
    let freshTitle = await OffMainActor.run { await writer.articleTitle(serverID: articleServerID) }
    if let freshTitle, freshTitle != visibleArticle.title {
        visibleArticle.title = freshTitle
        try? visibleArticle.modelContext?.save()
    }
}
```

(`writer` is already in scope from line 149.) Remove the now-unused `ArticleResolution.fetchByServerID` import path if nothing else in the file uses it.

- [ ] **Step 4: Run tests** — `-only-testing:YanaTests/SyncWriterTests`. PASS.
- [ ] **Step 5: Commit** — `git commit -am "Fetch the reloaded article's title off the main actor"`

---

### Task 5: Bound the per-article image fan-out (P4)

`backfillMissingContent`'s inner image loop (`SyncEngine.swift:245-249`) is an unbounded `withTaskGroup` nested inside the bounded-6 content loop: one 40-image article fires 40 concurrent downloads × up to 6 articles.

**Files:**
- Modify: `Yana/Services/SyncEngine.swift:245-249`

**Interfaces:**
- Consumes: the existing `runBounded(_:maxConcurrency:work:)` free function (`SyncEngine.swift:290`).

- [ ] **Step 1: Implement** — replace the inner group:

```swift
// Bounded like everything else in this pass: the outer content loop already runs 6 wide,
// so an image-heavy article must not multiply that by its image count (audit P4).
await runBounded(Array(Block.imageHashes(in: document.blocks)), maxConcurrency: 2) { hash in
    _ = await imageStore.fetchIfNeeded(hash: hash, client: client)
}
```

- [ ] **Step 2: Run** `-only-testing:YanaTests/SyncEngineTests -only-testing:YanaTests/RunBoundedTests`. PASS (behavioral result unchanged; `RunBoundedTests` already pins the bound mechanism).
- [ ] **Step 3: Commit** — `git commit -am "Bound the backfill's per-article image downloads instead of fanning out unbounded"`

---

### Task 6: Index `Feed.identifier`, batch the feed lookups, and add `fetchLimit = 1` (P5, P-batch)

`upsertSummaries` runs one **unindexed** `Feed` fetch per synced article (`SyncWriter.swift:64-69`; `Feed` has no `#Index` at all), and five single-row lookups fetch unlimited then take `.first`.

**Files:**
- Modify: `Yana/Models/Feed.swift` (add `#Index`)
- Modify: `Yana/Services/SyncWriter.swift` (feed map; `fetchLimit = 1` at lines 63, 115, 136 — already done in Task 3 — 156, 191)
- Test: `YanaTests/SyncWriterTests.swift` (existing suite is the regression net)

- [ ] **Step 1: Add the index**

In `Yana/Models/Feed.swift`, inside the class body (mirror `Article.swift:16-17`'s comment style):

```swift
// `SyncWriter` looks feeds up by `identifier` once per upsert batch and per /feeds replace.
#Index<Feed>([\.identifier])
```

- [ ] **Step 2: Build the feed map once per `upsertSummaries` call**

At the top of `upsertSummaries` (before the `for summary in summaries` loop):

```swift
// One fetch for the whole page instead of one unindexed fetch per summary (audit P5).
// The /feeds table is small (unpaginated server snapshot), so fetching it whole is cheap.
var feedsByIdentifier: [String: Feed] = [:]
if let feeds = try? modelContext.fetch(FetchDescriptor<Feed>()) {
    for feed in feeds { feedsByIdentifier[feed.identifier] = feed }
}
```

Inside the loop, delete the `feedDescriptor` fetch (lines 64-69) and use `let feed = feedsByIdentifier[summary.feedId.description]`.

- [ ] **Step 3: `fetchLimit = 1` everywhere a single row is taken**

At `SyncWriter.swift:63` (`existingDescriptor`), 115 (`applyContent`), 156 (`replaceFeeds`'s `fetchExisting`), 191 (`syncTags`'s `fetchExisting`): change `let descriptor = ...` to `var descriptor = ...` and add `descriptor.fetchLimit = 1` before the fetch. (`applyRemovals` got its limit in Task 3.)

- [ ] **Step 4: Run** `-only-testing:YanaTests/SyncWriterTests`. PASS. (The index addition is a lightweight migration; existing stores open unchanged.)
- [ ] **Step 5: Commit** — `git commit -am "Index Feed.identifier, look feeds up once per sync page, and cap single-row fetches"`

---

### Task 7: `TagFilter` fast path and allocation-free tag access (P6)

`TagFilter.apply` (`TimelineFiltering.swift:76-86`) has no empty-filter fast path (its siblings do), and `ArticleSummary.filterTagNames` (`:65`) is `Array(tagNames)` — a heap allocation per row, per filter pass, in the after-every-swipe pipeline.

**Files:**
- Modify: `Yana/Utilities/TimelineFiltering.swift`
- Modify: whichever file holds `Article`'s `TimelineFilterable` conformance (grep `filterTagNames` — CLAUDE.md says `Article.filterTagNames` exists)
- Test: `YanaTests/` — grep for the existing `TimelineFiltering`/`TagFilter` test suite and extend it

- [ ] **Step 1: Failing test** (in the existing tag-filter suite; adapt fixture names):

```swift
@Test func emptyFilterReturnsAllItemsIncludingUntagged() {
    let items = [taggedSummary, untaggedSummary]
    let out = TagFilter.apply(to: items, disabledTagNames: [], includeUntagged: true)
    #expect(out.count == items.count)
}
```

(This passes today too — it pins the fast path's semantics before the change. The compile-breaking part is Step 3's protocol change.)

- [ ] **Step 2: Change the protocol requirement to a `Set`**

In `TimelineFiltering.swift`, change `TimelineFilterable`'s requirement from `var filterTagNames: [String] { get }` to `var filterTagNames: Set<String> { get }`. Update `ArticleSummary`'s conformance (`:65`) to `var filterTagNames: Set<String> { tagNames }` (its `tagNames` is already a `Set<String>` — zero allocation). Grep `filterTagNames` repo-wide and update `Article`'s conformance the same way (if it builds an array from the tag join, return the `Set` it builds instead).

- [ ] **Step 3: Add the fast path**

```swift
static func apply<T: TimelineFilterable>(
    to items: [T], disabledTagNames: Set<String>, includeUntagged: Bool
) -> [T] {
    // Nothing disabled and untagged shown: the filter can't remove anything (audit P6).
    guard !disabledTagNames.isEmpty || !includeUntagged else { return items }
    return items.filter { item in
        let names = item.filterTagNames
        if names.isEmpty { return includeUntagged }
        return names.contains { !disabledTagNames.contains($0) }
    }
}
```

- [ ] **Step 4: Run** the filtering test suite + `-only-testing:YanaTests` (the conformance change can ripple). PASS.
- [ ] **Step 5: Commit** — `git commit -am "Give TagFilter an empty-filter fast path and stop allocating tag arrays per row"`

---

### Task 8: Cache `ArticleListView`'s filtered results outside `body` (P7)

`ArticleListView.results` (`ArticleListView.swift:33-40`) re-runs three whole-library filter passes inside `body` on every keystroke and every store mutation. The Mac sidebar already fixed exactly this (`MacRootView.swift:330-337` + `recomputeDisplayed()`); mirror it.

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift`

- [ ] **Step 1: Implement**

Replace the computed `results` with cached state, mirroring `MacSidebarView`:

```swift
/// Cached, not computed (mirrors MacSidebarView.displayed, audit P7): `body` re-runs on every
/// searchable keystroke and every store publish; the three filter passes only need to re-run
/// when one of their real inputs changes.
@State private var results: [ArticleSummary] = []

private func recomputeResults() {
    let base = searchResults ?? store.summaries
    let byTag = TagFilter.apply(to: base,
                                disabledTagNames: settings.disabledTagNames,
                                includeUntagged: settings.includeUntagged)
    let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
    results = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
}
```

In `body`, delete `let results = results` (the `@State` is read directly) and keep `let currentItemID = results.first { isCurrent($0) }?.id`. Attach after the existing `.task` modifiers:

```swift
.onAppear { recomputeResults() }
.onChange(of: store.summaries) { _, _ in recomputeResults() }
.onChange(of: searchResults) { _, _ in recomputeResults() }
.onChange(of: settings.disabledTagNames) { _, _ in recomputeResults() }
.onChange(of: settings.includeUntagged) { _, _ in recomputeResults() }
.onChange(of: settings.disabledFeedNames) { _, _ in recomputeResults() }
.onChange(of: settings.starredOnly) { _, _ in recomputeResults() }
```

- [ ] **Step 2: Build**, then run the UI-touching unit suites (`-only-testing:YanaTests`). PASS.
- [ ] **Step 3: Commit** — `git commit -am "Cache the article list's filtered rows instead of refiltering in body per keystroke"`

---

### Task 9: Route feed logos through `ReaderImageCache` (P8)

`FeedLogo.image` (`FeedLogoView.swift:7-14`) does `Data(contentsOf:)` + `UIImage(data:)` on the main actor per row with no decoded cache; `ReaderImageCache` already does decode-off-main, downsampling, and byte-limited caching for article images.

**Files:**
- Modify: `Yana/Views/Config/FeedLogoView.swift`

**Interfaces:**
- Consumes: `ReaderImageCache.shared.image(for:)` — confirm exact signature first via `grep -n "func image(for" Yana/Reader/ReaderImageCache.swift` (it is called as `await ReaderImageCache.shared.image(for: leadImageRef)` with a `yana-img://` ref string in `ArticleBlockView.swift:657`).

- [ ] **Step 1: Implement**

Replace `FeedLogo` and the `.task` in `FeedLogoView`:

```swift
/// Feed logos go through the same decoded-bitmap cache as article images (ReaderImageCache:
/// off-main decode, downsampling, byte-limited NSCache) instead of a per-row main-thread
/// Data(contentsOf:) + UIImage(data:) with no cache (audit P8).
struct FeedLogoView: View {
    let hash: String?
    var size: CGFloat = 28

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "globe")
                    .resizable().scaledToFit().padding(4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text("Feed logo"))
        .task(id: hash) {
            guard let hash else { image = nil; return }
            // Sync eagerly mirrors logos, but cover the cache-miss case (fresh install
            // mid-sync) exactly like before.
            if let client = AuthenticatedClient.current() {
                _ = await ImageStore.shared.fetchIfNeeded(hash: hash, client: client)
            }
            image = await ReaderImageCache.shared.image(for: "yana-img://\(hash)")
        }
    }
}
```

Delete the `FeedLogo` enum after confirming via grep that `FeedLogoView` was its only caller (audit noted `ArticleHeaderLogo.swift` — check it too; if it calls `FeedLogo.image`, point it at the same `ReaderImageCache` path).

- [ ] **Step 2: Build; run `-only-testing:YanaTests`** (an `ArticleHeaderLogoTests` suite existed historically — the audit says it was deleted, but verify). PASS.
- [ ] **Step 3: Commit** — `git commit -am "Load feed logos through ReaderImageCache instead of decoding on the main thread per row"`

---

### Task 10: Move full-text search off the main thread (P9)

`ArticleSearch.searchSummaries` (`ArticleSearch.swift:8-24`) is `@MainActor` and scans `plainText` — the heaviest column — synchronously on main per debounced keystroke.

**Files:**
- Modify: `Yana/Services/ArticleSearch.swift`
- Modify: `Yana/Views/Config/ArticleListView.swift` (`runSearch`)
- Modify: `Yana/Reader/Mac/MacRootView.swift` (`MacSidebarView.runSearch`)
- Test: `YanaTests/` — grep for an existing `ArticleSearch`-adjacent suite; add one if absent

**Interfaces:**
- Produces: `ArticleSearch.searchSummaries(query: String, container: ModelContainer) async -> [ArticleSummary]` (replaces the sync `in modelContext:` variant).
- Precondition to verify: `ArticleSummary: Sendable` (it crosses `OffMainActor.run` already in `ArticleSummaryLoader` — confirm with grep before starting).

- [ ] **Step 1: Failing test**

```swift
@Test func searchSummariesMatchesTitleOffMain() async throws {
    // seed an article titled "Solar Battery Breakthrough" into a throwaway container
    let hits = await ArticleSearch.searchSummaries(query: "battery", container: container)
    #expect(hits.count == 1)
    let misses = await ArticleSearch.searchSummaries(query: "zeppelin", container: container)
    #expect(misses.isEmpty)
}
```

- [ ] **Step 2: Run — fails to compile** (no such signature).

- [ ] **Step 3: Implement**

```swift
/// The predicate fetch runs on this @ModelActor, hopped off-main via OffMainActor.run --
/// plainText is the heaviest column in the store and localizedStandardContains over it must
/// never run on the main thread (audit P9). ArticleListSearch stays the single predicate
/// source shared with nothing else changed.
@ModelActor
actor ArticleSearcher {
    func searchSummaries(query: String) -> [ArticleSummary] {
        var descriptor = FetchDescriptor<Article>(
            predicate: ArticleListSearch.predicate(for: query),
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        descriptor.propertiesToFetch = ArticleSummary.fetchedProperties
        descriptor.relationshipKeyPathsForPrefetching = [\.feed]
        let matches = (try? modelContext.fetch(descriptor)) ?? []
        let tagNamesByID = ArticleSummary.tagNameLookup(in: modelContext)
        return matches.map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
    }
}

@MainActor
enum ArticleSearch {
    static func searchSummaries(query: String, container: ModelContainer) async -> [ArticleSummary] {
        let searcher = ArticleSearcher(modelContainer: container)
        return await OffMainActor.run { await searcher.searchSummaries(query: query) }
    }
}
```

(Keep `ArticleListSearch` untouched.) Update both call sites' `runSearch`:

```swift
private func runSearch() async {
    let q = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { searchResults = nil; return }
    searchResults = await ArticleSearch.searchSummaries(query: q, container: modelContext.container)
}
```

Note: results now come from a different `ModelContext`, but `ArticleSummary` is a value snapshot, so nothing downstream changes.

- [ ] **Step 4: Run the new test + full `YanaTests`.** PASS.
- [ ] **Step 5: Commit** — `git commit -am "Run full-text search on a model actor off the main thread"`

---

### Task 11: One writer for the backfill; give the store's coalescer a max-delay ceiling (P10)

Two halves: (a) `backfillMissingContent` constructs a fresh `SyncWriter` per article (`SyncEngine.swift:239`); (b) `TrailingCoalescer.schedule()` restarts its debounce on every save, so a sync whose saves land < 200ms apart starves `ArticleStore.applyPending` until the burst ends, accumulating the whole burst in `pending`.

**Files:**
- Modify: `Yana/Services/SyncEngine.swift:236-249`
- Modify: `Yana/Utilities/TrailingCoalescer.swift`
- Modify: `Yana/Services/ArticleStore.swift:185-187` (pass `maxDelay`)
- Test: `YanaTests/TrailingCoalescerTests.swift`

**Interfaces:**
- Produces: `TrailingCoalescer.init(interval: Duration, maxDelay: Duration? = nil, action: @escaping () async -> Void)` — `nil` preserves today's pure-debounce behavior for all other users.

- [ ] **Step 1: Failing test** (in `TrailingCoalescerTests`, matching its existing async style):

```swift
@Test func maxDelayFiresDuringAContinuousBurst() async throws {
    var fires = 0
    let coalescer = TrailingCoalescer(interval: .milliseconds(50), maxDelay: .milliseconds(120)) { fires += 1 }
    // Schedule every 20ms for 300ms: the 50ms quiet period never elapses,
    // so without maxDelay this would fire zero times during the burst.
    for _ in 0..<15 {
        coalescer.schedule()
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(fires >= 1)
}
```

- [ ] **Step 2: Run — fails** (no `maxDelay` parameter).

- [ ] **Step 3: Implement**

```swift
@MainActor
final class TrailingCoalescer {
    private let interval: Duration
    /// Optional ceiling: during a continuous trigger burst (each schedule() restarting the
    /// quiet-period timer), fire anyway once this much time has passed since the burst began,
    /// so a long sync burst can't starve the action indefinitely (audit P10).
    private let maxDelay: Duration?
    private let action: () async -> Void
    private var debounce: Task<Void, Never>?
    private var isRunning = false
    private var pending = false
    private var burstStart: ContinuousClock.Instant?

    init(interval: Duration, maxDelay: Duration? = nil, action: @escaping () async -> Void) {
        self.interval = interval
        self.maxDelay = maxDelay
        self.action = action
    }

    func schedule() {
        let now = ContinuousClock.now
        if burstStart == nil { burstStart = now }
        if let maxDelay, let start = burstStart, now - start >= maxDelay {
            debounce?.cancel()
            debounce = nil
            Task { [weak self] in await self?.fire() }
            return
        }
        debounce?.cancel()
        let interval = interval
        debounce = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    func fireNow() async {
        debounce?.cancel()
        debounce = nil
        await fire()
    }

    private func fire() async {
        burstStart = nil
        guard !isRunning else { pending = true; return }
        isRunning = true
        await action()
        isRunning = false
        if pending {
            pending = false
            await fire()
        }
    }
}
```

In `ArticleStore.start` (line 185): `refreshCoalescer = TrailingCoalescer(interval: .milliseconds(200), maxDelay: .seconds(1)) { ... }`. Leave `cacheCoalescer` without a ceiling (a delayed cache write is the point).

- [ ] **Step 4: Hoist the backfill writer**

In `backfillMissingContent`, add `let writer = SyncWriter(modelContainer: container)` above the `runBounded` call (there is already one at line 221 for the pending fetch — reuse that same `writer` by capturing it) and delete the per-item construction at line 239. The actor serializes its own writes, so sharing is safe; saves stay per-apply (each is one article's blocks — batching them across a shared context risks losing more on a mid-backfill kill).

- [ ] **Step 5: Run** `-only-testing:YanaTests/TrailingCoalescerTests -only-testing:YanaTests/ArticleStoreIncrementalTests -only-testing:YanaTests/SyncReactionMainThreadTests`. PASS.
- [ ] **Step 6: Commit** — `git commit -am "Share one backfill writer and let the store's coalescer fire during long save bursts"`

---

### Task 12: Small-perf sweep: single-pass unread badge, bounded language detection (P-minor, reader-perf finding 9)

**Files:**
- Modify: `Yana/Services/UnreadBadgeUpdater.swift:15-22`
- Modify: `Yana/Reader/ReaderSpeechController.swift:222-228` (`voice(for:)`)
- Test: existing `UnreadBadgeUpdater` suite (grep for it; extend if present, add if not)

- [ ] **Step 1: Pin behavior** — ensure a test exists asserting `UnreadBadgeUpdater.count` over a mixed fixture (read/unread × tagged/untagged × starred × disabled-feed). Add one if missing:

```swift
@Test func countHonorsAllFiltersInOnePass() {
    let settings = AppSettings()  // follow the suite's isolated-defaults pattern if it has one
    settings.disabledFeedNames = ["Muted Feed"]
    settings.starredOnly = false
    let summaries = [unreadTagged, readTagged, unreadInMutedFeed, unreadUntagged]
    #expect(UnreadBadgeUpdater.count(from: summaries, settings: settings) == 2)
}
```

- [ ] **Step 2: Rewrite `count` as one allocation-free pass**

```swift
static func count(from summaries: [ArticleSummary], settings: AppSettings) -> Int {
    let disabledTags = settings.disabledTagNames
    let includeUntagged = settings.includeUntagged
    let disabledFeeds = settings.disabledFeedNames
    let starredOnly = settings.starredOnly
    var count = 0
    for s in summaries where !s.isRead {
        if starredOnly && !s.isStarred { continue }
        if !s.feedName.isEmpty && disabledFeeds.contains(s.feedName) { continue }
        if s.tagNames.isEmpty {
            if !includeUntagged { continue }
        } else if !s.tagNames.contains(where: { !disabledTags.contains($0) }) {
            continue
        }
        count += 1
    }
    return count
}
```

(Semantics identical to the three-pass pipeline; the test from Step 1 proves it.)

- [ ] **Step 3: Bound the speech language sniff** — in `ReaderSpeechController.voice(for:)`, feed the recognizer a prefix instead of the whole article: `recognizer.processString(String(text.prefix(2000)))` with a comment: `// Language detection needs a couple of sentences, not the whole article (audit).`

- [ ] **Step 4: Run the badge suite + build.** PASS.
- [ ] **Step 5: Commit** — `git commit -am "Count the unread badge in one pass and bound the read-aloud language sniff"`

---

### Task 13: Surface pairing failures distinctly from cancellation (U1)

Every non-success pairing outcome — session error, anti-forgery `stateMismatch`, malformed callback — collapses into `onCancel` (`DevicePairingView.swift:83-108`), and `OnboardingServerPage` shows nothing. Make classification a pure, tested function; show an inline error for real failures; stay silent for a user cancel.

**Files:**
- Modify: `Yana/Services/DevicePairing.swift` (new `PairingFailure` + `classify`)
- Modify: `Yana/Views/DevicePairingView.swift` (forward the error; call `classify`)
- Modify: `Yana/Views/Onboarding/OnboardingServerPage.swift` (error state + copy)
- Modify: `Yana/Resources/Localizable.xcstrings`
- Test: `YanaTests/DevicePairingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PairingFailure: Equatable { case cancelled, sessionFailed, stateMismatch, malformedCallback }
  enum PairingOutcome: Equatable { case paired(token: String), failed(PairingFailure) }
  static func classify(callbackURL: URL?, error: (any Error)?, session: DevicePairingSession) -> PairingOutcome
  ```
- `DevicePairingView` gains `let onFailed: (PairingFailure) -> Void`; `onCancel` fires only for `.cancelled`.

- [ ] **Step 1: Failing tests** (in `DevicePairingTests`, alongside the existing `handleCallback` tests):

```swift
@Test func classifyMapsCancelToCancelled() {
    let err = ASWebAuthenticationSessionError(.canceledLogin)
    #expect(DevicePairing.classify(callbackURL: nil, error: err, session: session) == .failed(.cancelled))
}

@Test func classifyMapsOtherErrorsToSessionFailed() {
    struct Boom: Error {}
    #expect(DevicePairing.classify(callbackURL: nil, error: Boom(), session: session) == .failed(.sessionFailed))
}

@Test func classifyMapsNilURLNoErrorToCancelled() {
    #expect(DevicePairing.classify(callbackURL: nil, error: nil, session: session) == .failed(.cancelled))
}

@Test func classifyForwardsStateMismatch() {
    let url = URL(string: "yana://auth-callback?token=t&state=WRONG")!
    #expect(DevicePairing.classify(callbackURL: url, error: nil, session: session) == .failed(.stateMismatch))
}

@Test func classifyForwardsSuccess() {
    let url = URL(string: "yana://auth-callback?token=tok&state=\(session.state)")!
    #expect(DevicePairing.classify(callbackURL: url, error: nil, session: session) == .paired(token: "tok"))
}
```

(`import AuthenticationServices` in the test file.)

- [ ] **Step 2: Run — fails to compile.**

- [ ] **Step 3: Implement `classify` in `DevicePairing.swift`**

```swift
import AuthenticationServices

enum PairingFailure: Equatable { case cancelled, sessionFailed, stateMismatch, malformedCallback }
enum PairingOutcome: Equatable { case paired(token: String), failed(PairingFailure) }

extension DevicePairing {
    /// Pure classification of an ASWebAuthenticationSession completion, so the four genuinely
    /// different failure modes (user cancel, session/transport failure, anti-forgery state
    /// mismatch, malformed callback) stop collapsing into one silent "cancelled" (audit U1).
    static func classify(callbackURL: URL?, error: (any Error)?, session: DevicePairingSession) -> PairingOutcome {
        if let error {
            if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                return .failed(.cancelled)
            }
            return .failed(.sessionFailed)
        }
        guard let callbackURL else { return .failed(.cancelled) }
        switch handleCallback(callbackURL, session: session) {
        case .success(let token): return .paired(token: token)
        case .stateMismatch: return .failed(.stateMismatch)
        case .malformedCallback: return .failed(.malformedCallback)
        }
    }
}
```

- [ ] **Step 4: Forward the error through the coordinator's main-thread hop**

The existing hop (`perform(#selector...)`) carries only one object. Box both values:

```swift
/// Carries the ASWebAuthenticationSession completion across the ObjC main-thread hop —
/// `perform(_:on:with:)` takes a single object, and we need both the URL and the error.
private final class PairingCallbackBox: NSObject {
    let url: URL?
    let error: (any Error)?
    init(url: URL?, error: (any Error)?) { self.url = url; self.error = error }
}
```

In `DevicePairingCoordinator` (keep the `nonisolated` + `perform` mechanism exactly as-is — its doc comment explains the Catalyst trap):

```swift
nonisolated private func handleAuthCallback(_ callbackURL: URL?, _ error: (any Error)?) {
    perform(#selector(finishFromCallback(_:)), on: Thread.main,
            with: PairingCallbackBox(url: callbackURL, error: error), waitUntilDone: false)
}

@objc private func finishFromCallback(_ box: Any?) {
    let box = box as? PairingCallbackBox
    finish(callbackURL: box?.url, error: box?.error)
}

private func finish(callbackURL: URL?, error: (any Error)?) {
    session = nil
    guard let pairingSession else { onCancel?(); return }
    switch DevicePairing.classify(callbackURL: callbackURL, error: error, session: pairingSession) {
    case .paired(let token): onPaired?(token)
    case .failed(.cancelled): onCancel?()
    case .failed(let failure): onFailed?(failure)
    }
}
```

Add `let onFailed: (PairingFailure) -> Void` to `DevicePairingView` (threaded into the coordinator's `start` like the other two callbacks).

- [ ] **Step 5: Show the error in `OnboardingServerPage`**

Add `@State private var pairingFailure: PairingFailure?`. Clear it in `signIn()` and in the `onChange(of: serverURLText)` handler. Pass to the view:

```swift
onCancel: { isPairing = false },
onFailed: { failure in
    isPairing = false
    pairingFailure = failure
}
```

Under the Sign In card (after the `card { ... }` block at line 156-165), before the demo-content footnote:

```swift
if let pairingFailure {
    Text(Self.failureMessage(pairingFailure))
        .font(.footnote)
        .foregroundStyle(.red)
        .padding(.horizontal, 4)
}
```

```swift
static func failureMessage(_ failure: PairingFailure) -> String {
    switch failure {
    case .cancelled:
        return ""   // never shown; .cancelled routes to onCancel
    case .sessionFailed:
        return String(localized: "Sign-in didn't complete. Check that the address points to a running Yana Server and try again.")
    case .stateMismatch, .malformedCallback:
        return String(localized: "The server's response could not be verified. Please try signing in again.")
    }
}
```

- [ ] **Step 6: Add the strings to `Localizable.xcstrings`** (mirror the JSON shape of an existing single-language entry, `de` marked `translated`):
  - "Sign-in didn't complete. Check that the address points to a running Yana Server and try again." → de: "Die Anmeldung wurde nicht abgeschlossen. Bitte prüfen, ob die Adresse auf einen laufenden Yana Server zeigt, und es erneut versuchen."
  - "The server's response could not be verified. Please try signing in again." → de: "Die Antwort des Servers konnte nicht überprüft werden. Bitte die Anmeldung erneut versuchen."

- [ ] **Step 7: Run** `-only-testing:YanaTests/DevicePairingTests` + build. PASS.
- [ ] **Step 8: Commit** — `git commit -am "Tell the user when pairing fails instead of silently closing the sheet"`

---

### Task 14: Preserve a subpath in the pairing URL (U6)

`DevicePairing.pairingURL` assigns `login.path = "/login"`, which **replaces** the base URL's path — a server at `https://host/yana` gets sent to `https://host/login`. Every other consumer appends.

**Files:**
- Modify: `Yana/Services/DevicePairing.swift:34-37`
- Test: `YanaTests/DevicePairingTests.swift`

- [ ] **Step 1: Failing test**

```swift
@Test func pairingURLPreservesBasePath() {
    let base = URL(string: "https://host.example/yana")!
    let url = DevicePairing.pairingURL(serverBaseURL: base, session: session, deviceName: "d")
    #expect(url.path == "/yana/login")
}

@Test func pairingURLHandlesTrailingSlashBase() {
    let base = URL(string: "https://host.example/yana/")!
    let url = DevicePairing.pairingURL(serverBaseURL: base, session: session, deviceName: "d")
    #expect(url.path == "/yana/login")
}
```

- [ ] **Step 2: Run — fails** (`/login` today).

- [ ] **Step 3: Implement**

```swift
var login = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false)!
// Append, don't replace: a server reverse-proxied under a path prefix keeps it (audit U6).
let basePath = login.path.hasSuffix("/") ? String(login.path.dropLast()) : login.path
login.path = basePath + "/login"
login.queryItems = [URLQueryItem(name: "next", value: nextString)]
return login.url!
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `git commit -am "Keep a reverse-proxy subpath when building the pairing login URL"`

---

### Task 15: Trim the server URL and split the validation copy (U7)

A pasted URL with a trailing space/newline fails `URL(string:)` and the user is told to "include https://" — which is already there.

**Files:**
- Modify: `Yana/Views/Onboarding/OnboardingServerPage.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

- [ ] **Step 1: Implement trimming**

In `OnboardingServerPage`:

```swift
private var trimmedServerURLText: String {
    serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
}

private var validatedServerURL: URL? {
    guard let url = URL(string: trimmedServerURLText),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else {
        return nil
    }
    return url
}
```

Persist the trimmed form: in `onPaired` change `settings.serverBaseURL = serverURLText` to `settings.serverBaseURL = trimmedServerURLText`, and update `pairedURLText` assignments to use it too (both in `onPaired` and `onAppear` comparison stays consistent because `settings.serverBaseURL` is now always trimmed).

- [ ] **Step 2: Split the error copy** (line 142-146):

```swift
if !trimmedServerURLText.isEmpty, validatedServerURL == nil {
    Text(trimmedServerURLText.lowercased().hasPrefix("http")
         ? "This doesn't look like a valid server address."
         : "Enter a full address, including https://.")
        .font(.footnote)
        .foregroundStyle(.red)
        .padding(.horizontal, 4)
}
```

- [ ] **Step 3: Add the new string** — "This doesn't look like a valid server address." → de: "Das scheint keine gültige Serveradresse zu sein." (`translated`).
- [ ] **Step 4: Build + run `-only-testing:YanaTests`.** PASS.
- [ ] **Step 5: Commit** — `git commit -am "Trim pasted server addresses and stop blaming a missing https prefix for every invalid URL"`

---

### Task 16: Detect a revoked session at foreground and immediately after sync rejects it (U2)

`presentWelcomeIfNeeded()` runs only from `ContentView.onAppear`. A token revoked mid-session leaves the app silently degraded until relaunch (worst on Mac, which stays open for days).

**Files:**
- Modify: `Yana/Services/SyncEngine.swift` (post a notification from both `unauthorized` catches)
- Modify: `Yana/ContentView.swift` (scenePhase re-check + notification observer)

**Interfaces:**
- Produces: `extension Notification.Name { static let yanaSessionInvalidated: Notification.Name }` (declare in `SyncEngine.swift`).

- [ ] **Step 1: Implement the notification**

In `SyncEngine.swift`, file scope:

```swift
extension Notification.Name {
    /// Posted when a sync discovers the stored device token has been revoked/expired and
    /// deletes it. ContentView re-runs its re-pairing gate on receipt so the user is prompted
    /// now, not at the next relaunch (audit U2).
    static let yanaSessionInvalidated = Notification.Name("yanaSessionInvalidated")
}
```

After `KeychainService.deleteDeviceToken()` at line 97 AND inside the backfill catch at line 258, add:

```swift
NotificationCenter.default.post(name: .yanaSessionInvalidated, object: nil)
```

(Posting from the off-main backfill closure is fine — the observer below hops to main.)

- [ ] **Step 2: React in `ContentView`**

Add `@Environment(\.scenePhase) private var scenePhase` and, on the root `Group`'s modifier chain (next to the existing `.onAppear`):

```swift
.onChange(of: scenePhase) { _, phase in
    // A session revoked while backgrounded (or while this window sat open on the Mac)
    // must re-prompt on return, not at next relaunch (audit U2).
    if phase == .active { presentWelcomeIfNeeded() }
}
.onReceive(NotificationCenter.default.publisher(for: .yanaSessionInvalidated).receive(on: RunLoop.main)) { _ in
    presentWelcomeIfNeeded()
}
```

`presentWelcomeIfNeeded` already no-ops when nothing is wrong (`WelcomeGate.neededStep` returns nil) and under UI-test skip args, so this is safe to call repeatedly.

- [ ] **Step 3: Build + run existing `YanaTests` (WelcomeGate suite covers the gate logic).** PASS.
- [ ] **Step 4: Commit** — `git commit -am "Prompt for re-pairing the moment a revoked session is detected, not at next launch"`

---

### Task 17: Show a real failure state when the first sync fails, on both platforms (U3, Mac finding 7)

`InitialSyncGate.run` gives up after 5 attempts with no signal; the user lands on "Add your first feed" against a server that's full of articles. Also: the initial-sync loading gate renders only on iOS (`ContentView.swift:40-44`); Mac shows nothing.

**Files:**
- Modify: `Yana/Services/InitialSyncGate.swift` (testable seam + failure flag)
- Modify: `Yana/Models/AppState.swift` (`initialSyncFailed`)
- Create: `Yana/Views/InitialSyncFailedView.swift`
- Modify: `Yana/ContentView.swift` (iOS branch + retry)
- Modify: `Yana/Reader/Mac/MacRootView.swift` (detail-pane gate)
- Modify: `Yana/Resources/Localizable.xcstrings`
- Test: `YanaTests/InitialSyncGateTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  static func run(container:client:articleStore:appState:settings:,
                  retryDelay: Duration = .seconds(3),
                  syncOnce: (() async throws -> Void)? = nil) async
  ```
  (`syncOnce` defaults to the real `SyncEngine.sync()`; tests inject.) `AppState.initialSyncFailed: Bool`.

- [ ] **Step 1: Failing tests** (new file `YanaTests/InitialSyncGateTests.swift`; use the repo's throwaway-container + `AppSettings` isolation patterns from `TestHelper.swift`):

```swift
@Test func failedFirstSyncSetsFailureFlagAndDoesNotMarkComplete() async {
    let appState = AppState()
    settings.hasCompletedInitialSync = false
    struct Boom: Error {}
    await InitialSyncGate.run(
        container: container, client: client, articleStore: store,
        appState: appState, settings: settings,
        retryDelay: .milliseconds(1),
        syncOnce: { throw Boom() }
    )
    #expect(appState.initialSyncFailed)
    #expect(!settings.hasCompletedInitialSync)
    #expect(!appState.isPerformingInitialSync)
}

@Test func successfulFirstSyncClearsFailureAndMarksComplete() async {
    let appState = AppState()
    appState.initialSyncFailed = true
    settings.hasCompletedInitialSync = false
    await InitialSyncGate.run(
        container: container, client: client, articleStore: store,
        appState: appState, settings: settings,
        retryDelay: .milliseconds(1),
        syncOnce: {}
    )
    #expect(!appState.initialSyncFailed)
    #expect(settings.hasCompletedInitialSync)
}
```

(`client` can be any `YanaAPIClient` instance — with `syncOnce` injected it is never used; construct it with a dummy URL/token as the existing networking tests do.)

- [ ] **Step 2: Run — fails to compile.**

- [ ] **Step 3: Implement the gate changes**

`AppState`: add

```swift
/// True when the device's very first sync exhausted its retries without completing --
/// drives the "couldn't reach your server" state with a Retry (audit U3). Cleared when a
/// retry starts. Meaningless once `hasCompletedInitialSync` is set.
var initialSyncFailed = false
```

`InitialSyncGate.run`: new signature per Interfaces; body:

```swift
let sync: () async throws -> Void = syncOnce ?? {
    _ = try await SyncEngine(container: container, client: client).sync()
}

guard !settings.hasCompletedInitialSync else {
    try? await sync()
    return
}

appState.isPerformingInitialSync = true
appState.initialSyncFailed = false
var succeeded = false
var unauthorized = false
for attempt in 0..<maxAttempts {
    do {
        try await sync()
        succeeded = true
        break
    } catch YanaAPIClientError.unauthorized {
        unauthorized = true
        break
    } catch {
        guard attempt < maxAttempts - 1 else { break }
        try? await Task.sleep(for: retryDelay)
    }
}

if succeeded {
    await articleStore.refreshNow()
    settings.hasCompletedInitialSync = true
} else if !unauthorized {
    // Unauthorized routes through the re-pairing gate instead (Task 16); everything else
    // is "couldn't reach the server" and gets an explicit retry state.
    appState.initialSyncFailed = true
}
appState.isPerformingInitialSync = false
```

(Keep `maxAttempts = 5` and the doc comments; `retryDelay` moves from a static to the parameter default.)

- [ ] **Step 4: The failure view**

Create `Yana/Views/InitialSyncFailedView.swift`:

```swift
import SwiftUI

/// Shown instead of the reader when the very first sync after pairing exhausted its retries.
/// Without this the user landed on the empty-library "add your first feed" state against a
/// server that is actually full of articles (audit U3).
struct InitialSyncFailedView: View {
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Reach Your Server", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Pairing succeeded, but your articles couldn't be loaded. Check your connection and try again.")
        } actions: {
            Button("Try Again", action: onRetry).buttonStyle(.borderedProminent)
        }
    }
}
```

- [ ] **Step 5: Wire it into both roots**

`ContentView.body` (lines 39-46) becomes:

```swift
if isMac {
    MacRootView(appState: appState, settings: settings)
} else if appState.isPerformingInitialSync {
    InitialSyncLoadingView()
} else if appState.initialSyncFailed, !settings.hasCompletedInitialSync {
    InitialSyncFailedView { retryInitialSync() }
} else {
    ReaderScreen(appState: appState)
}
```

with

```swift
private func retryInitialSync() {
    guard let client = AuthenticatedClient.current() else { return }
    appState.initialSyncFailed = false
    Task {
        await InitialSyncGate.run(
            container: AppContainer.shared, client: client,
            articleStore: store, appState: appState, settings: settings
        )
    }
}
```

`MacRootView.detail` (lines 132-154) gains the same two gates ahead of the empty check:

```swift
@ViewBuilder private var detail: some View {
    if appState.isPerformingInitialSync {
        InitialSyncLoadingView()
    } else if appState.initialSyncFailed, !settings.hasCompletedInitialSync {
        InitialSyncFailedView { retryInitialSync() }
    } else if model.filteredArticles.isEmpty {
        ...unchanged...
```

with an identical `retryInitialSync()` on `MacRootView` (it has `store` via `@Environment(ArticleStore.self)` and `settings`).

- [ ] **Step 6: Strings** — add with `de` `translated`:
  - "Couldn't Reach Your Server" → "Server nicht erreichbar"
  - "Pairing succeeded, but your articles couldn't be loaded. Check your connection and try again." → "Die Kopplung war erfolgreich, aber die Artikel konnten nicht geladen werden. Bitte die Verbindung prüfen und es erneut versuchen."
  - "Try Again" — check the catalog first; `ManagementWebView` already has a "Try Again" key. Reuse it if present.

- [ ] **Step 7: Run** the new suite + `PairingSyncTests` (its call sites pass the new defaulted params untouched). PASS.
- [ ] **Step 8: Commit** — `git commit -am "Show a retryable failure state when the first sync can't reach the server"`

---

### Task 18: Make the Mac refresh loop honor setting changes, window focus, and the foreground (U4, Mac finding 13)

`schedule()` is called exactly once (launch), so: launched `.off` → no loop ever; interval changes ignored; the "window-focus runNow()" CLAUDE.md describes doesn't exist; and Mac refreshes post "new articles" notifications while the user is looking at the window.

**Files:**
- Modify: `Yana/Services/BackgroundRefreshManager.swift`
- Modify: `Yana/YanaApp.swift`
- Test: `YanaTests/BackgroundRefreshManagerTests.swift` (grep for the existing suite name)

- [ ] **Step 1: `schedule()` cancels the Mac loop on `.off`**

```swift
func schedule() {
    guard let seconds = secondsProvider() else {
        #if targetEnvironment(macCatalyst)
        // Interval switched to .off while a loop is armed: kill it (audit U4).
        macRefreshLoop?.cancel()
        macRefreshLoop = nil
        #endif
        return
    }
    ...rest unchanged...
```

- [ ] **Step 2: Suppress foreground notifications on Mac**

`runRefresh` gains a parameter: `static func runRefresh(engine: SyncEngine, notifier: Notifying = NotificationService(), settings: AppSettings = AppSettings(), postsNotification: Bool = true) async`, with the notification block wrapped in `guard postsNotification, settings.notificationsEnabled, inserted > 0 else { return }`. In `scheduleMac`'s loop body and in `runNow()`, pass `postsNotification: UIApplication.shared.applicationState != .active` (add `import UIKit` if missing; both call sites are `@MainActor`). The iOS `handle(task:)` path keeps the default `true`.

- [ ] **Step 3: Expose re-arm + focus refresh on `AppDelegate`**

In `AppDelegate` (YanaApp.swift):

```swift
/// Re-arm scheduling after the user changes the update interval -- on iOS the next BGTask
/// re-schedules itself, but the Mac loop is armed once at launch and never re-read the
/// setting (audit U4).
@MainActor func rearmBackgroundRefresh() { backgroundRefresh.schedule() }

#if targetEnvironment(macCatalyst)
@MainActor func refreshOnFocus() { backgroundRefresh.runNow() }
#endif
```

- [ ] **Step 4: Drive them from the scene**

In `YanaApp`'s `.onChange(of: scenePhase)` `.active` branch, add:

```swift
#if targetEnvironment(macCatalyst)
appDelegate.refreshOnFocus()
#endif
```

and add a sibling modifier:

```swift
.onChange(of: appSettings.updateInterval) { _, _ in
    appDelegate.rearmBackgroundRefresh()
}
```

- [ ] **Step 5: Test what's testable on iOS** — the Mac loop is `#if`-excluded from the simulator suite. Add/extend a test that `runRefresh(postsNotification: false)` never calls the notifier even with inserts (the suite already has a `Notifying` spy if it tests notification posting; otherwise add a minimal spy conforming to `Notifying`).

- [ ] **Step 6: Build for Mac Catalyst too** (compile check only — signing is unavailable in this shell per project memory): `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO`. Expected: builds.
- [ ] **Step 7: Commit** — `git commit -am "Re-arm the Mac refresh loop on interval changes, refresh on focus, and stop foreground notifications"`

---

### Task 19: Make pull-to-refresh's spinner track the real update (U5)

`RefreshableIfAvailable` (`ArticleBlockView.swift:678-692`) dismisses after a fixed 400ms while the real poll runs up to ~30s; in full-screen mode the nav-bar fallback spinner is hidden, so nothing indicates progress and users re-pull (restarting the run).

**Files:**
- Modify: `Yana/Services/UpdateActivity.swift` (new `waitUntilIdle`)
- Modify: `Yana/Reader/ArticleBlockView.swift` (`RefreshableIfAvailable`)
- Test: `YanaTests/UpdateActivityTests.swift` (grep; extend or create)

- [ ] **Step 1: Failing test**

```swift
@Test func waitUntilIdleReturnsImmediatelyWhenIdle() async {
    let start = ContinuousClock.now
    await UpdateActivity.shared.waitUntilIdle(pollInterval: .milliseconds(10), timeout: .seconds(1))
    #expect(ContinuousClock.now - start < .milliseconds(500))
}

@Test func waitUntilIdleOutlivesARunningUpdate() async {
    let activity = UpdateActivity()   // if init is private, add an internal test init or use .shared serially
    let task = activity.restart { try? await Task.sleep(for: .milliseconds(100)) }
    await activity.waitUntilIdle(pollInterval: .milliseconds(10), timeout: .seconds(2))
    #expect(!activity.isUpdating)
    _ = await task.value
}
```

(Check `UpdateActivity`'s init visibility; it has no `private init`, so direct construction works.)

- [ ] **Step 2: Run — fails to compile.**

- [ ] **Step 3: Implement `waitUntilIdle`**

```swift
/// Await the end of the current update burst, bounded. Polling (not a continuation chain)
/// keeps this trivially correct against restart()'s cancel-and-replace behavior; the poll is
/// coarse because its only consumer is the pull-to-refresh gesture spinner (audit U5).
func waitUntilIdle(pollInterval: Duration = .milliseconds(200), timeout: Duration = .seconds(35)) async {
    let deadline = ContinuousClock.now + timeout
    while isUpdating, ContinuousClock.now < deadline {
        try? await Task.sleep(for: pollInterval)
    }
}
```

- [ ] **Step 4: Hold the gesture spinner**

```swift
private struct RefreshableIfAvailable: ViewModifier {
    let onRefresh: (() -> Void)?
    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable {
                onRefresh()
                // Let restart() actually begin before sampling isUpdating...
                try? await Task.sleep(nanoseconds: 400_000_000)
                // ...then keep the system spinner up until the run really finishes, instead
                // of lying with a fixed 400ms dismissal while the poll runs ~30s (audit U5).
                await UpdateActivity.shared.waitUntilIdle()
            }
        } else {
            content
        }
    }
}
```

- [ ] **Step 5: Run tests + build.** PASS.
- [ ] **Step 6: Commit** — `git commit -am "Keep the pull-to-refresh spinner up until the update really finishes"`

---

### Task 20: Give iOS a visible "Update all" action (U11)

On iPhone the only way to trigger the app's most important action is the unlabeled pull gesture; Mac has a toolbar button and ⌘R.

**Files:**
- Modify: `Yana/Reader/ReaderArticleViewController.swift` (`buildMenuActions`, lines 626-676)

- [ ] **Step 1: Implement**

In `buildMenuActions()`, build the update action once at the top:

```swift
let updateAction: UIAction? = (hasServer && onRefresh != nil) ? UIAction(
    title: String(localized: "Update all"),
    image: UIImage(systemName: "arrow.clockwise")
) { [weak self] _ in self?.onRefresh?() } : nil
```

In the zero-state branch, include it: `return [UIMenu(title: "", options: .displayInline, children: [updateAction, settingsAction].compactMap { $0 })]`. In the main path, insert `if let updateAction { actions.append(updateAction) }` immediately before the Reload block, so the menu reads Update all → Reload → Copy link → …

("Update all" already exists in the catalog for the Mac command — verify with grep; if the key is missing add it: de "Alle aktualisieren".)

- [ ] **Step 2: Build; run `YanaUITests`' settings-independent smoke if quick, else unit bundle.** PASS.
- [ ] **Step 3: Commit** — `git commit -am "Add Update all to the reader's overflow menu on iOS"`

---

### Task 21: Article-list UX: reload feedback, honest empty state, filter accessibility, visible stop control (U9, U10, U16a, U16b)

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

- [ ] **Step 1: Reload toast (U9)**

Add `@State private var toast: ToastMessage?` and `.toast($toast)` to the modifier chain (after `.sheet(isPresented: $showFilter)`). Rewrite the reload swipe action's body to go through the same shared path the reader uses:

```swift
Button {
    guard let article = article(for: summary),
          let client = AuthenticatedClient.current(),
          let serverID = article.serverID
    else { return }
    UpdateActivity.shared.restart {
        let result = await ReaderActions.forceUpdateArticle(
            article, serverID: serverID, client: client, container: modelContext.container
        )
        switch result {
        case .cancelled:
            return
        case .applied(let feedName):
            toast = ToastMessage(text: RefreshOutcome.message(newCount: 0, feedName: feedName))
        case .failed:
            toast = ToastMessage(
                text: String(localized: "Could not reload this article. Please try again."),
                style: .error
            )
        }
    }
} label: {
    Label("Reload", systemImage: "arrow.trianglehead.2.clockwise")
}
.tint(.orange)
```

(Both strings already exist in the catalog — `ReaderHostView` uses them.) `ReaderActions.forceUpdateArticle` passes `visibleArticle` internally, preserving the old live-object update.

- [ ] **Step 2: Honest empty state (U10)** — line 66: change `emptyDescription` to `"No articles yet. Update all from the reader, or add feeds on your server."` New string, de: "Noch keine Artikel. Im Reader „Alle aktualisieren“ ausführen oder Feeds auf dem Server hinzufügen." Remove the old key `"No articles yet. Add feeds, then pull to refresh."` from the catalog if nothing else uses it (grep).

- [ ] **Step 3: Filter accessibility (U16a)** — on the filter `ToolbarItem` button (lines 144-150), add:

```swift
.accessibilityLabel(Text("Filter articles"))
.accessibilityValue(isFilterActive ? Text("Filter active") : Text(""))
```

("Filter articles" exists — the reader uses it. Add "Filter active" → de: "Filter aktiv".)

- [ ] **Step 4: Visible stop control (U16b)** — replace the bare `ProgressView()` label (lines 138-143):

```swift
if isUpdating {
    Button { UpdateActivity.shared.cancel() } label: {
        ZStack {
            ProgressView()
            Image(systemName: "stop.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
    .accessibilityLabel(Text("Stop updating"))
}
```

- [ ] **Step 5: Build + run unit bundle.** PASS.
- [ ] **Step 6: Commit** — `git commit -am "Give the article list reload feedback, an honest empty state, and a visible stop control"`

---

### Task 22: Show read state in the Mac sidebar (U8)

The Mac row renders star state but never `isRead`; iOS shows an accent dot.

**Files:**
- Modify: `Yana/Reader/Mac/MacRootView.swift` (`MacArticleRow`, lines 531-554)

- [ ] **Step 1: Implement**

In `MacArticleRow.body`, wrap the title in the unread marker and de-emphasize read titles:

```swift
VStack(alignment: .leading, spacing: 5) {
    HStack(alignment: .top, spacing: 6) {
        if !summary.isRead {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .accessibilityLabel(Text("Unread"))
        }
        Text(summary.title)
            .font(.headline)
            .foregroundStyle(titleColor)
            .lineLimit(3)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
    ...subline unchanged...
```

with (mirroring the existing `feedNameColor` selected-row pattern):

```swift
/// Read titles recede like a mail client's; the selected row keeps the system's white text.
private var titleColor: Color {
    if isSelected { return .white }
    return summary.isRead ? Color.secondary : Color.primary
}
```

("Unread" exists in the catalog — iOS uses it.)

- [ ] **Step 2: Catalyst build check** (`CODE_SIGNING_ALLOWED=NO` as in Task 18). Builds.
- [ ] **Step 3: Commit** — `git commit -am "Show unread state in the Mac sidebar"`

---

### Task 23: Guard Mac `openWebsite` and unify its label (U13, Mac finding 10/11)

`TimelineModel.openWebsite` hands any server-supplied scheme to `UIApplication.shared.open`; iOS guards http/https. The same action is labeled "Open Page" (toolbar) and "Open in Browser" (everywhere else). The "Use System Browser" toggle shows on Mac where this action ignores it.

**Files:**
- Modify: `Yana/Reader/Mac/TimelineModel.swift:241-246`
- Modify: `Yana/Reader/Mac/MacRootView.swift:201,204`
- Modify: `Yana/Views/Config/Settings/ReaderSettingsSection.swift` (hide the toggle on Catalyst)
- Modify: `Yana/Resources/Localizable.xcstrings` (drop "Open Page")

- [ ] **Step 1: Scheme guard**

```swift
func openWebsite(_ article: Article) {
    #if canImport(UIKit)
    // Same guard as iOS (ReaderArticleViewController.openInBrowser): article.url is
    // server-supplied feed data, so never hand a non-web scheme to LSOpen (audit).
    guard let url = URL(string: article.url),
          url.scheme == "http" || url.scheme == "https" else { return }
    UIApplication.shared.open(url)
    #endif
}
```

- [ ] **Step 2: Label unification** — `MacRootView.swift:201` and the `.help` at 204: "Open Page" → "Open in Browser". Remove the "Open Page" entry from `Localizable.xcstrings` (grep confirms no other user).

- [ ] **Step 3: Hide the dead toggle on Mac** — in `ReaderSettingsSection.swift`, wrap the "Use System Browser" `Toggle` (around lines 35-38 — read the file for exact bounds) in `#if !targetEnvironment(macCatalyst)` with a comment: `// The Mac always opens the default browser (TimelineModel.openWebsite), so the toggle would lie there.`

- [ ] **Step 4: Build both destinations; commit** — `git commit -am "Guard Mac link opening to web schemes and unify the Open in Browser label"`

---

### Task 24: Mark as Read/Unread everywhere, plus `ArticleWrites.setRead` (U12 part 1)

No manual read-state control exists anywhere in the app. Add the write primitive and expose it on both platforms.

**Files:**
- Modify: `Yana/Services/ArticleWrites.swift`
- Modify: `Yana/Reader/Mac/TimelineModel.swift` (`toggleRead`)
- Modify: `Yana/Reader/Mac/MacCommands.swift` (menu item)
- Modify: `Yana/Reader/Mac/MacRootView.swift` (context-menu item)
- Modify: `Yana/Resources/Localizable.xcstrings`
- Test: grep for the existing `ArticleWrites` test suite; extend it

**Interfaces:**
- Produces: `ArticleWrites.setRead(_ article: Article, read: Bool, modelContext: ModelContext)`; `TimelineModel.toggleRead(_ article: Article)`.

- [ ] **Step 1: Read `Yana/Services/ArticleWrites.swift` first.** `markRead` flips the flag, saves, and fires/queues the PATCH (per CLAUDE.md "Starring and marking read are both optimistic, funneled through the shared ArticleWrites facade"). Generalize its body into `setRead(_:read:modelContext:)` (guard `article.read != read` instead of `!article.read`; send the explicit value in the PATCH/pending-write payload), then reimplement `markRead(_:modelContext:)` as `setRead(article, read: true, modelContext: modelContext)` so every existing call site is untouched.

- [ ] **Step 2: Failing test** (in the `ArticleWrites` suite, following its fixtures):

```swift
@Test func setReadCanMarkUnread() async throws {
    let article = seededArticle(read: true)
    ArticleWrites.setRead(article, read: false, modelContext: context)
    #expect(article.read == false)
}
```

- [ ] **Step 3: Implement; run the suite.** PASS.

- [ ] **Step 4: Mac surfaces**

`TimelineModel`:

```swift
func toggleRead(_ article: Article) {
    guard let modelContext else { return }
    ArticleWrites.setRead(article, read: !article.read, modelContext: modelContext)
}
```

`YanaCommands` (after the Star button):

```swift
Button(readToggleTitle) { if let a = model?.selectedArticle() { model?.toggleRead(a) } }
    .keyboardShortcut("u", modifiers: [.command, .shift])
    .disabled(model?.selectedSummary == nil)
```

```swift
private var readToggleTitle: LocalizedStringKey {
    (model?.selectedSummary?.isRead ?? false) ? "Mark as Unread" : "Mark as Read"
}
```

`MacArticleRow.contextMenuItems` (from Task 2's rewrite — add after the Star button):

```swift
Button {
    if let article = model.resolve(summary) { model.toggleRead(article) }
} label: {
    Label(summary.isRead ? "Mark as Unread" : "Mark as Read",
          systemImage: summary.isRead ? "circle.fill" : "circle")
}
```

- [ ] **Step 5: Strings** — "Mark as Read" → de "Als gelesen markieren"; "Mark as Unread" → de "Als ungelesen markieren" (`translated`).

- [ ] **Step 6: Build both destinations; run unit bundle. Commit** — `git commit -am "Add manual mark as read and unread on the Mac, backed by ArticleWrites.setRead"`

---

### Task 25: Mac menu/context completeness: Settings menu, Find, Summarize command, Delete, Share (U12 part 2, Mac findings 8/9/15)

**Files:**
- Modify: `Yana/Reader/Mac/MacCommands.swift`
- Modify: `Yana/Reader/Mac/TimelineModel.swift` (search-focus token; delete)
- Modify: `Yana/Reader/Mac/MacRootView.swift` (sidebar focus wiring; context menu; delete alert)
- Modify: `Yana/Resources/Localizable.xcstrings`

- [ ] **Step 1: Settings in the app menu**

In `YanaCommands`, add `@Environment(\.openWindow) private var openWindow` and:

```swift
CommandGroup(replacing: .appSettings) {
    Button("Settings…") { openWindow(id: WindowID.settings, value: true) }
        .keyboardShortcut(",", modifiers: .command)
}
```

Remove the `.keyboardShortcut(",", modifiers: .command)` from the toolbar overflow's Settings button (`MacRootView.swift:219`) so the shortcut isn't claimed twice (keep the button). New string "Settings…" → de "Einstellungen …".

- [ ] **Step 2: Summarize in the Article menu** (after Read Aloud):

```swift
Button("Summarize") { if let a = model?.selectedArticle() { model?.summarize(a) } }
    .keyboardShortcut("s", modifiers: [.command, .shift])
    .disabled(model?.selectedSummary == nil || model?.isSummarizing == true || model?.aiReady != true)
```

- [ ] **Step 3: Find (⌘F) focuses the sidebar search**

`TimelineModel`:

```swift
/// Bumped by the Find menu command; MacSidebarView observes it and focuses the search field.
private(set) var searchFocusToken = 0
func requestSearchFocus() { searchFocusToken += 1 }
```

`YanaCommands`:

```swift
CommandGroup(replacing: .textEditing) {
    Button("Find") { model?.requestSearchFocus() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(model == nil)
}
```

`MacSidebarView`: add `@FocusState private var searchFieldFocused: Bool`, attach `.searchFocused($searchFieldFocused)` directly after `.searchable(...)`, and:

```swift
.onChange(of: model.searchFocusToken) { _, _ in searchFieldFocused = true }
```

New string "Find" → de "Suchen".

- [ ] **Step 4: Delete from the sidebar context menu, with the iOS confirmation**

`TimelineModel`:

```swift
/// Set from a row's Delete context item; MacRootView presents the confirmation alert
/// bound to it (a context-menu button cannot present its own alert).
var summaryPendingDelete: ArticleSummary?

func deleteArticle(_ summary: ArticleSummary) {
    guard let modelContext, let article = resolve(summary) else { return }
    modelContext.delete(article)
    try? modelContext.save()
    settings.imagePruneNeeded = true   // same flag the iOS delete sets (Task 3)
}
```

(`settings` is `private let` in `TimelineModel` — it is already stored; use it.) In `MacArticleRow.contextMenuItems`, append after the Reload/Summarize section:

```swift
Divider()
Button(role: .destructive) {
    model.summaryPendingDelete = summary
} label: { Label("Delete", systemImage: "trash") }
```

In `MacRootView.body`, add alongside the other sheet/alert modifiers:

```swift
.alert(
    String(localized: "Delete Article?"),
    isPresented: Binding(
        get: { model.summaryPendingDelete != nil },
        set: { if !$0 { model.summaryPendingDelete = nil } }
    )
) {
    if let summary = model.summaryPendingDelete {
        Button(String(localized: "Delete"), role: .destructive) { model.deleteArticle(summary) }
    }
    Button(String(localized: "Cancel"), role: .cancel) {}
} message: {
    if let summary = model.summaryPendingDelete {
        Text(String(localized: "Delete \u{201C}\(summary.title)\u{201D}? This cannot be undone."))
    }
}
```

(All three strings exist — iOS `ArticleListView` uses them.)

- [ ] **Step 5: Share from the context menu** (Mac finding 15) — in `contextMenuItems`, inside the `hasServer` group after "Open in Browser":

```swift
if let url = URL(string: summary.identifier), url.scheme == "http" || url.scheme == "https" {
    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
}
```

(`ArticleSummary.identifier` is the article URL — same field `Article.url` mirrors. Verify with grep that `ArticleSummary` exposes `identifier`; it does — the row `.tag(summary.identifier)` uses it.) New string "Share" → de "Teilen" (check catalog first).

- [ ] **Step 6: Build Catalyst + iOS; run unit bundle. Commit** — `git commit -am "Fill the Mac menu bar and context menu: Settings, Find, Summarize, Delete, Share"`

---

### Task 26: Mac odds and ends: Add-Feed affordance, Settings pane persistence, Mac-correct Settings copy (Mac findings 14/16/17)

**Files:**
- Modify: `Yana/Reader/Mac/MacRootView.swift` (`MacFilterBar` gets the add button; wire `onCreateFeed`)
- Modify: `Yana/Reader/Mac/MacSettingsWindow.swift` (persist pane)
- Modify: `Yana/Models/AppSettings.swift` (`macSettingsPane: String`)
- Modify: `Yana/Views/Config/Settings/NotificationsSettingsSection.swift`, `Yana/Views/Config/Settings/ReaderSettingsSection.swift` (Catalyst copy)
- Modify: `Yana/Resources/Localizable.xcstrings`

- [ ] **Step 1: Use the dead `onCreateFeed` (finding 16)**

`MacFilterBar` gains `let onCreateFeed: () -> Void` and an add button:

```swift
HStack {
    Menu { ...existing... } label: { ...existing... }
    Spacer()
    Button(action: onCreateFeed) { Image(systemName: "plus") }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Add Feed"))
        .help(Text("Add Feed"))
}
.padding(.horizontal, 12)
...
```

`MacSidebarView` passes it through: `MacFilterBar(settings: settings, onCreateFeed: onCreateFeed)` — the previously-dead parameter now has a real consumer. ("Add Feed" exists in the catalog.)

- [ ] **Step 2: Persist the Settings pane (finding 17)**

`AppSettings`: add `macSettingsPane: String` (UserDefaults-backed, default `""`), mirroring `macSidebarWidth`'s implementation pattern exactly. `MacSettingsWindow`:

```swift
.onAppear {
    if let restored = SettingsPane(rawValue: settings.macSettingsPane) { selection = restored }
}
.onChange(of: selection) { _, pane in
    settings.macSettingsPane = pane?.rawValue ?? ""
}
```

(`MacSettingsWindow` already has `settings` in scope via `@Environment(AppSettings.self)` — verify; add if not. `SettingsPane` is `String`-raw-valued per `WindowID.swift` — verify with a read.)

- [ ] **Step 3: Mac-correct instructions (finding 14)**

In `NotificationsSettingsSection.swift:49` and `ReaderSettingsSection.swift:52`, read the exact current sentences, then branch:

```swift
#if targetEnvironment(macCatalyst)
Text("Enable notifications for Yana in System Settings under Notifications.")
#else
Text(<existing iOS sentence, unchanged>)
#endif
```

and for the voice hint the Catalyst variant: "To add more voices, open System Settings, then Accessibility, then Spoken Content." German for the two new strings: "Mitteilungen für Yana in den Systemeinstellungen unter „Mitteilungen“ aktivieren." and "Weitere Stimmen lassen sich in den Systemeinstellungen unter „Bedienungshilfen“ und „Gesprochene Inhalte“ hinzufügen." (Prose rule: no arrows/dashes in user copy — the sentences above use words instead.)

- [ ] **Step 4: Build Catalyst + iOS. Commit** — `git commit -am "Add a sidebar Add Feed button, remember the Settings pane, and correct Mac Settings copy"`

---

### Task 27: Localization repairs: missing keys, German plural agreement, deleted-feature copy (U14, U15)

**Files:**
- Modify: `Yana/Resources/Localizable.xcstrings`
- Modify: `Yana/Utilities/RefreshOutcome.swift`
- Modify: `Yana/Views/WelcomeView.swift:38,240`
- Test: `YanaTests/PluralAgreementTests.swift`

- [ ] **Step 1: Failing plural tests**

Add to `PluralAgreementTests` (follow its explicit-`.lproj`-bundle pattern exactly — the file's comments explain why):

```swift
@Test func addedNewArticlesAgreesInBothLanguages() {
    #expect(localized("Added %lld new articles.", count: 1, lang: "en") == "Added 1 new article.")
    #expect(localized("Added %lld new articles.", count: 2, lang: "en") == "Added 2 new articles.")
    #expect(localized("Added %lld new articles.", count: 1, lang: "de") == "1 neuer Artikel hinzugefügt.")
    #expect(localized("Added %lld new articles.", count: 2, lang: "de") == "2 neue Artikel hinzugefügt.")
}
```

(Reuse the suite's existing helper for formatting against a pinned bundle; add a two-arg variant check for the feed-name key at count 1/2 the same way.)

- [ ] **Step 2: Run — fails** (keys don't exist yet).

- [ ] **Step 3: Rework `RefreshOutcome`**

```swift
static func message(newCount: Int, feedName: String?) -> String {
    if newCount == 0 {
        if let name = feedName {
            return String(localized: "Reloaded \u{201C}\(name)\u{201D}.")
        }
        return String(localized: "No new articles.")
    }
    if let name = feedName {
        return String(localized: "Added \(newCount) new articles from \u{201C}\(name)\u{201D}.")
    }
    return String(localized: "Added \(newCount) new articles.")
}
```

Catalog entries (both keys get explicit `en` AND `de` `variations.plural.{one,other}` blocks — `"%lld entries"` in the catalog is the reference shape to copy):
- `"Added %lld new articles."` — en one: "Added %lld new article." / other: "Added %lld new articles."; de one: "%lld neuer Artikel hinzugefügt." / other: "%lld neue Artikel hinzugefügt."
- `"Added %lld new articles from \u{201C}%@\u{201D}."` — en one: "Added %lld new article from “%@”." / other: "Added %lld new articles from “%@”."; de one: "%lld neuer Artikel von „%@“ hinzugefügt." / other: "%lld neue Artikel von „%@“ hinzugefügt."

Delete the now-orphaned keys `"article"`, `"articles"`, `"Added %lld new %@."`, and the with-feed-name variant (grep each key first to confirm `RefreshOutcome` was the only consumer).

- [ ] **Step 4: The four missing keys (U14)** — add with `de` `translated`, mirroring the JSON shape of the adjacent "Welcome to Yana" entry:
  - "Connect to Your Server" → "Mit dem eigenen Server verbinden"
  - "Choose Your AI" → "KI auswählen"
  - "A quick update on what changed, and your options." → "Ein kurzer Überblick über die Änderungen und die verfügbaren Optionen."
  - (The fourth missing key, the AI subtitle, is replaced in Step 5 rather than translated as-is.)

- [ ] **Step 5: Remove the deleted-feature promises (U15)**

`WelcomeView.swift:38` (headerSubtitle for `.aiMode`): replace with `"Summarize articles with your server's AI provider or with Apple Intelligence on this device."` → de "Artikel zusammenfassen, mit dem KI-Anbieter des Servers oder mit Apple Intelligence auf diesem Gerät."

`WelcomeView.swift:240` (the "Optional AI" feature detail): replace with `"Summarize articles with your server's AI provider, or entirely on-device with Apple Intelligence."` → de "Artikel zusammenfassen, mit dem KI-Anbieter des Servers oder komplett auf dem Gerät mit Apple Intelligence." Remove the old key ("Summarize, improve, or translate articles — via your server's AI provider, or entirely on-device with Apple Intelligence.") and its de entry.

(Note both new sentences avoid em dashes, per the copy rule.)

- [ ] **Step 6: Run `PluralAgreementTests` + full unit bundle.** PASS.
- [ ] **Step 7: Commit** — `git commit -am "Repair German onboarding strings, plural agreement in refresh toasts, and stale AI copy"`

---

### Task 28: `DemoModeBanner` survives accessibility text sizes (U16c)

The banner is a rigid single-row `HStack`; at accessibility sizes the labels truncate or push "Pair Now" off-screen.

**Files:**
- Modify: `Yana/Views/DemoModeBanner.swift`

- [ ] **Step 1: Implement** — split the row into reusable pieces and branch on type size (`ViewThatFits` also works, but an explicit branch is deterministic to test by inspection):

```swift
struct DemoModeBanner: View {
    var onPairNow: () -> Void
    var onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        icon
                        text
                        Spacer(minLength: 8)
                        dismissButton
                    }
                    pairButton
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    text
                    Spacer(minLength: 8)
                    pairButton
                    dismissButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("demoModeBanner")
    }

    private var icon: some View {
        Image(systemName: "sparkles").foregroundStyle(.orange).accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("You're viewing demo content").font(.subheadline.weight(.semibold))
            Text("Pair a Yana Server to sync your real feeds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pairButton: some View {
        Button("Pair Now", action: onPairNow)
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark").foregroundStyle(.secondary)
        }
        .accessibilityLabel(Text("Dismiss"))
    }
}
```

- [ ] **Step 2: Build. Commit** — `git commit -am "Let the demo banner stack vertically at accessibility text sizes"`

---

### Task 29: Fix the stale Mac screenshot test pane id (drift)

`MacScreenshotUITests.swift:107,109` selects pane `"feeds"`, which `SettingsPane` no longer has.

**Files:**
- Modify: `YanaUITests/MacScreenshotUITests.swift:107,109`

- [ ] **Step 1:** Change both `"feeds"` occurrences to `"manage"` (the pane that hosts `ManagementWebView`, matching the `03_Feeds` shot's intent). First confirm `SettingsPane.manage.rawValue == "manage"` in `Yana/Reader/Mac/WindowID.swift`.
- [ ] **Step 2:** Mac Catalyst UI tests can't run from this shell (signing; see project memory) — compile-check the test target: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing CODE_SIGNING_ALLOWED=NO`. Builds.
- [ ] **Step 3: Commit** — `git commit -am "Point the Mac screenshot test at the manage pane that replaced feeds"`

---

### Task 30: Update CLAUDE.md for everything above (drift; per the updating-project-docs skill)

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Fix the confirmed drift**
  - Remove the `MacFormStyle` mention (line ~513) — the type does not exist; only `MacToolbarStyle` does.
  - Correct the `OnboardingAIModePage` description (~493): it does NOT "just embed `AIModeSettingsSection`"; describe it as a separate implementation per the file's own header.
  - Rewrite the Mac background-refresh sentence (~416-418) to describe the *new* truth from Task 18: interval changes re-arm the loop, `.off` cancels it, window focus triggers `runNow()`, and foreground runs suppress notifications.
  - Add a short paragraph documenting `InitialSyncGate` (first-sync gate + failure/retry state from Task 17), `PairingSync`, `ServerDisconnect`, and `InitialSyncLoadingView`/`InitialSyncFailedView` under **Architecture** — they are load-bearing and currently undocumented.
- [ ] **Step 2: Document the new behaviors this plan added** (one line each, in the matching sections): the image-prune gate (`AppSettings.imagePruneNeeded`, Task 3), the cached device token (Task 1), the pairing-failure surface (Task 13), `ArticleWrites.setRead` (Task 24), the `yanaSessionInvalidated` re-pair trigger (Task 16), and the updated test counts if suites were added.
- [ ] **Step 3: Update the "Tests" section** — the `MacScreenshotUITests` stale-`"feeds"` caveat is fixed by Task 29; remove it.
- [ ] **Step 4: Commit** — `git commit -am "Update CLAUDE.md for the audit fixes"`

---

### Task 31: Full verification pass

- [ ] **Step 1:** `xcodegen generate` (only needed if any file was **created**: `InitialSyncFailedView.swift`, `InitialSyncGateTests.swift` — project.yml globs may cover them, but regenerate to be safe), then run the complete suite: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`. Expected: all suites pass (381+ unit tests plus the ones added here; `YanaUITests` needs the simulator — remember `-UITEST_RESET_LIBRARY` semantics if a UI test misbehaves, per CLAUDE.md).
- [ ] **Step 2:** Catalyst compile check: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO`.
- [ ] **Step 3:** Grep sweeps: no remaining `AuthenticatedClient.current()` inside a per-row `@ViewBuilder`; no `fetch(` in `SyncWriter` without `fetchLimit` where `.first` follows; every new string present in `Localizable.xcstrings` with `de` marked `translated` (script the check with `python3 -c` against the JSON as done during the audit).
- [ ] **Step 4:** Fix anything found, re-run, commit — `git commit -am "Verification fixes for the audit plan"` (only if changes were needed).
