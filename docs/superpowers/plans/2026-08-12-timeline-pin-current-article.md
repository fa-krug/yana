# Pin Currently-Displayed Article's Sort Position — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the history-dependent `TimelineDisplayOrder.merge` (which still lets the reader
pager visibly reshuffle when the current article is marked read) with a stateless, always-correct
`TimelinePinning` transform, apply it uniformly to the iOS reader, the Mac sidebar (which had no
protection at all), and the article list's browsing mode.

**Architecture:** One pure function, `TimelinePinning.apply(to:pinning:)`, added to
`Yana/Utilities/TimelineFiltering.swift` alongside the existing `TagFilter`/`FeedFilter`/
`StarredFilter`. It takes an already `(readRank, date)`-sorted array plus a pinned identifier, and —
only if that identifier's row is currently `read` — reinserts it at the date-sorted position it would
occupy among the unread rows. `TimelineDisplayOrder` is deleted outright. Three call sites adopt the
new function: `ReaderHostView.recomputeFilter` (iOS), `TimelineModel.recomputeFilter` (Mac, newly
protected), and `ArticleListView.results` (browsing mode only).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`import Testing`, `@Test`/`@Suite`).

## Global Constraints

- No change to `ArticleWrites.markRead`'s call sites or timing — the `read`/`readRank` flag is still
  set immediately everywhere it is today.
- `TimelineDisplayOrder` and its `preservingOrder` parameter split are deleted, not kept as a
  fallback or deprecated alias.
- Every new/changed user-facing string needs a `Localizable.xcstrings` entry for `en` and `de` — this
  plan adds no new user-facing strings, so this constraint has no work item, but do not introduce one
  without translating it.
- Follow existing file conventions: filter/sort primitives live in `Yana/Utilities/TimelineFiltering.swift`; tests for that file live in `YanaTests/TimelineFilteringTests.swift` /
  a new sibling test file, not inline elsewhere.

---

### Task 1: Add `TimelinePinning` and delete `TimelineDisplayOrder`

**Files:**
- Modify: `Yana/Utilities/TimelineFiltering.swift:14-16` (the `TimelineIdentifiable` protocol),
  `Yana/Utilities/TimelineFiltering.swift:108-151` (delete `TimelineDisplayOrder`, add
  `TimelinePinning` in its place)
- Delete: `YanaTests/TimelineDisplayOrderTests.swift`
- Create: `YanaTests/TimelinePinningTests.swift`

**Interfaces:**
- Produces: `TimelineIdentifiable` protocol gains `var date: Date { get }` (in addition to its
  existing `var identifier: String { get }`). `Article` and `ArticleSummary` both already have a
  stored `date: Date` property, so their existing `extension X: TimelineIdentifiable {}`
  conformances need no changes.
- Produces: `TimelinePinning.apply<T: TimelineIdentifiable & TimelineFilterable>(to articles: [T], pinning pinnedIdentifier: String?) -> [T]`. Consumed by Task 2 (`ReaderHostView`), Task 3
  (`TimelineModel`), and Task 4 (`ArticleListView`).

- [ ] **Step 1: Write the failing tests in a new file**

Create `YanaTests/TimelinePinningTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Timeline pinning")
struct TimelinePinningTests {
    private func article(_ id: String, date: TimeInterval, read: Bool = false) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.date = Date(timeIntervalSince1970: date)
        a.setRead(read)
        return a
    }

    /// Canonical (readRank, date) order for a/b/c/d: unread block first (oldest->newest), then
    /// read block (oldest->newest). Used as the "already sorted" input every test below starts from.
    private func canonical() -> [Article] {
        [
            article("a", date: 1),               // unread
            article("c", date: 3),                // unread
            article("d", date: 4),                // unread
            article("b", date: 2, read: true),     // read
        ]
    }

    @Test func noPinReturnsInputUnchanged() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: nil)
        #expect(result.map(\.identifier) == ["a", "c", "d", "b"])
    }

    @Test func unknownPinnedIdentifierReturnsInputUnchanged() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "missing")
        #expect(result.map(\.identifier) == ["a", "c", "d", "b"])
    }

    @Test func pinningAStillUnreadArticleIsANoOp() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "a")
        #expect(result.map(\.identifier) == ["a", "c", "d", "b"])
    }

    /// The core fix: "b" is read (date 2) but pinned, so it's reinserted into the unread block at
    /// the position its date would sort to -- between "a" (date 1) and "c" (date 3) -- instead of
    /// staying at the back of the read block.
    @Test func pinnedReadArticleIsReinsertedAtItsDateSortedUnreadPosition() {
        let input = canonical()
        let result = TimelinePinning.apply(to: input, pinning: "b")
        #expect(result.map(\.identifier) == ["a", "b", "c", "d"])
    }

    /// A pinned article older than every unread row sorts to the very front of the unread block.
    @Test func pinnedReadArticleOlderThanAllUnreadSortsFirst() {
        let input = [
            article("x", date: 5),
            article("y", date: 10),
            article("z", date: 1, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["z", "x", "y"])
    }

    /// A pinned article newer than every unread row sorts to the very back of the unread block,
    /// i.e. immediately ahead of the (now empty-of-it) read block.
    @Test func pinnedReadArticleNewerThanAllUnreadSortsLastInUnreadBlock() {
        let input = [
            article("x", date: 1),
            article("y", date: 2),
            article("z", date: 99, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["x", "y", "z"])
    }

    /// No unread rows at all: the pinned article becomes the sole occupant of the (now nonempty)
    /// unread block, ahead of every other read row.
    @Test func pinnedReadArticleWithNoUnreadRowsSortsFirst() {
        let input = [
            article("other", date: 1, read: true),
            article("z", date: 2, read: true),
        ]
        let result = TimelinePinning.apply(to: input, pinning: "z")
        #expect(result.map(\.identifier) == ["z", "other"])
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail to compile (no `TimelinePinning` yet)**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelinePinningTests`
Expected: build failure — `Cannot find 'TimelinePinning' in scope` (and `Article` does not yet
conform to `TimelineFilterable & TimelineIdentifiable` with the `date` requirement, but that part
already exists via `Article.date`, so the only missing piece is the new type).

- [ ] **Step 3: Delete the old test file**

```bash
git rm YanaTests/TimelineDisplayOrderTests.swift
```

- [ ] **Step 4: Replace `TimelineDisplayOrder` with `TimelinePinning` in `Yana/Utilities/TimelineFiltering.swift`**

First, add `date` to the protocol (around line 14):

```swift
/// Items addressable by their stable `identifier` (the timeline anchor key) and orderable by their
/// display `date`.
protocol TimelineIdentifiable {
    var identifier: String { get }
    var date: Date { get }
}
```

Then delete the entire `TimelineDisplayOrder` enum (current lines 108-151) and replace it with:

```swift
/// Reinserts the currently-displayed article's row at the position it would occupy if it were
/// still unread, whenever it has actually been marked read. `ArticleWrites.markRead` sets the
/// `read` flag the instant an article becomes current (pager swipe, list-open, sidebar selection),
/// which would otherwise immediately move that row from the unread block into the read block --
/// reshuffling the timeline out from under the user mid-navigation. This is a pure, stateless
/// transform recomputed fresh from `articles` every call (never a diff against a remembered
/// previous array), so it can't drift the way a history-dependent merge can: it's correct
/// regardless of what changed underneath it (filter toggles, sync-driven insertions/removals,
/// reopening the list).
///
/// `articles` must already be in canonical `(isRead, date)` order (ascending: read block first,
/// then unread block, each block oldest-first) -- the same order `TagFilter`/`FeedFilter`/`StarredFilter` preserve from
/// `ArticleStore.summaries`. `identifier` is only a per-feed dedup key (see `SummaryIndexMerge`'s
/// doc comment) so a pin could in principle match the wrong one of two same-identifier rows from
/// different feeds; this is an accepted, pre-existing limitation of using `identifier` as a lookup
/// key throughout this file, not something new here.
enum TimelinePinning {
    static func apply<T: TimelineIdentifiable & TimelineFilterable>(
        to articles: [T], pinning pinnedIdentifier: String?
    ) -> [T] {
        guard let pinnedIdentifier,
              let pinnedIndex = articles.firstIndex(where: { $0.identifier == pinnedIdentifier }),
              articles[pinnedIndex].filterRead
        else { return articles }

        var result = articles
        let pinned = result.remove(at: pinnedIndex)
        let unreadEnd = result.firstIndex(where: { $0.filterRead }) ?? result.count
        let insertionIndex = result[0..<unreadEnd].firstIndex { $0.date > pinned.date } ?? unreadEnd
        result.insert(pinned, at: insertionIndex)
        return result
    }
}
```

- [ ] **Step 5: Run the new tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelinePinningTests`
Expected: all 7 tests PASS.

- [ ] **Step 6: Run the full existing filtering test suite to make sure nothing else broke**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineFilteringTests`
Expected: PASS (this suite doesn't touch `TimelineDisplayOrder`, so it should be unaffected, but the
protocol change touches the same file).

- [ ] **Step 7: Commit**

```bash
git add Yana/Utilities/TimelineFiltering.swift YanaTests/TimelinePinningTests.swift
git rm YanaTests/TimelineDisplayOrderTests.swift
git commit -m "Replace TimelineDisplayOrder merge with stateless TimelinePinning"
```

---

### Task 2: Wire `TimelinePinning` into the iOS reader (`ReaderHostView`)

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift:145-184` (`recomputeFilter`, `applyTimeline`),
  `Yana/Reader/ReaderHostView.swift:325-328` (the filter `.onChange` handlers),
  `Yana/Reader/ReaderHostView.swift:349-359` (`openArticle`)

**Interfaces:**
- Consumes: `TimelinePinning.apply(to:pinning:)` from Task 1.
- Produces: `recomputeFilter()` (no parameters — the `preservingOrder: Bool` parameter is removed).
  No other file calls `ReaderHostView.recomputeFilter` today (it's a private method on
  `ReaderScreen`), so this is a self-contained signature change.

- [ ] **Step 1: Replace `recomputeFilter`'s body and drop the `preservingOrder` parameter**

Replace (current lines 145-161):

```swift
    /// Re-filter `store.summaries`. By default preserves `filteredArticles`' existing display
    /// order (see `TimelineDisplayOrder.merge`) rather than adopting the freshly-filtered array's
    /// read/unread + date sort wholesale; pass `preservingOrder: false` for a deliberate
    /// user-driven filter change (tag/feed/starred-only toggle), where a fresh sort is the
    /// expected result.
    private func recomputeFilter(preservingOrder: Bool = true) {
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        filteredArticles = preservingOrder
            ? TimelineDisplayOrder.merge(previous: filteredArticles, canonical: canonical)
            : canonical
    }
```

with:

```swift
    /// Re-filter `store.summaries`, then pin the currently-displayed article's position (see
    /// `TimelinePinning`) so marking it read doesn't reshuffle the timeline out from under the user.
    private func recomputeFilter() {
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        filteredArticles = TimelinePinning.apply(to: canonical, pinning: settings.timelineAnchorIdentifier)
    }
```

- [ ] **Step 2: Update the filter-toggle `.onChange` handlers (drop the now-gone parameter)**

Replace (current lines 325-328):

```swift
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeFilter(preservingOrder: false) }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeFilter(preservingOrder: false) }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeFilter(preservingOrder: false) }
        .onChange(of: settings.starredOnly) { _, _ in recomputeFilter(preservingOrder: false) }
```

with:

```swift
        .onChange(of: settings.disabledTagNames) { _, _ in recomputeFilter() }
        .onChange(of: settings.includeUntagged) { _, _ in recomputeFilter() }
        .onChange(of: settings.disabledFeedNames) { _, _ in recomputeFilter() }
        .onChange(of: settings.starredOnly) { _, _ in recomputeFilter() }
```

- [ ] **Step 3: Update `openArticle`'s call (current line 350) — drop the parameter**

`openArticle` already calls `recomputeFilter()` with no arguments (the default), so this line needs
no change:

```swift
    private func openArticle(_ summary: ArticleSummary) {
        recomputeFilter()
        ...
```

Confirm this line still reads exactly that way (it does) — no edit needed here, this step is a
verification checkpoint only.

- [ ] **Step 4: Build to confirm no remaining references to the removed parameter or `TimelineDisplayOrder`**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED, no errors about `preservingOrder` or `TimelineDisplayOrder`.

No automated test is added in this task: `ReaderScreen`/`ReaderHostView`/`ReaderArticleViewController`
have no unit-test harness in this codebase today (per `ReaderAnchorController`'s own doc comment —
UIKit view-controller logic here isn't unit-testable the way extracted controller classes are), and
`TimelinePinning.apply` itself is already fully covered by Task 1's tests. Manual verification of the
iOS pager happens in Task 5, Step 3.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift
git commit -m "Pin the reader's current article instead of merge-preserving order"
```

---

### Task 3: Wire `TimelinePinning` into the Mac sidebar (`TimelineModel`)

**Files:**
- Modify: `Yana/Reader/Mac/TimelineModel.swift:148-157` (`recomputeFilter`)
- Test: `YanaTests/TimelineModelTests.swift`

**Interfaces:**
- Consumes: `TimelinePinning.apply(to:pinning:)` from Task 1; `settings.timelineAnchorIdentifier`
  (already a stored property on `AppSettings`, already updated by `anchorWriter.record` immediately
  before `ArticleWrites.markRead` in both `selection`'s setter and `moveSelection`).
- Produces: no signature change — `recomputeFilter()` already takes no parameters.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/TimelineModelTests.swift`, near the other selection tests (after
`moveSelectionMarksTheNewArticleRead`, around current line 106):

```swift
    /// The bug this guards against: before this fix, `TimelineModel.recomputeFilter()` had no
    /// order-preservation at all, so marking "b" read the instant it's selected immediately moved
    /// it to the back of the read block on the very next recompute -- reshuffling the sidebar under
    /// the user's cursor. `model.selection = "b"` itself doesn't trigger a recompute (that normally
    /// happens asynchronously via the `store.summaries` -> `.onChange` -> `applyTimeline` chain
    /// `MacRootView` wires up outside this test's scope), so this test calls `recomputeFilter()`
    /// directly to exercise exactly the code path that chain would eventually run.
    @Test func settingSelectionKeepsThePinnedArticleAheadOfTheReadBlockAfterRecompute() async throws {
        let settings = freshSettings()
        let (model, store) = try makeConfiguredModel(settings: settings)
        await store.refreshNow()
        model.applyTimeline()   // parks on "a" per the helper's 3-article a/b/c fixture (dates 1,2,3)

        model.selection = "b"   // marks "b" read; canonical order alone would become [a, c, b]
        model.recomputeFilter()

        #expect(model.filteredArticles.map(\.identifier) == ["a", "b", "c"],
                "the just-selected 'b', now read, must stay pinned ahead of the still-unread 'c'")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineModelTests/settingSelectionKeepsThePinnedArticleAheadOfTheReadBlockAfterRecompute`
Expected: FAIL — `model.filteredArticles.map(\.identifier)` is `["a", "c", "b"]` (canonical order,
unprotected).

- [ ] **Step 3: Update `recomputeFilter()`**

Replace (current lines 148-157):

```swift
    func recomputeFilter() {
        guard let store else { return }
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        filteredArticles = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
    }
```

with:

```swift
    func recomputeFilter() {
        guard let store else { return }
        let byTag = TagFilter.apply(
            to: store.summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        filteredArticles = TimelinePinning.apply(to: canonical, pinning: settings.timelineAnchorIdentifier)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TimelineModelTests`
Expected: all tests in the suite PASS, including the new one.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/Mac/TimelineModel.swift YanaTests/TimelineModelTests.swift
git commit -m "Pin the Mac sidebar's current article to stop it reshuffling on selection"
```

---

### Task 4: Wire `TimelinePinning` into the article list (`ArticleListView`)

**Files:**
- Modify: `Yana/Views/Config/ArticleListView.swift:58-67` (`results`)
- Test: `YanaTests/ArticleListFilterTests.swift`

**Interfaces:**
- Consumes: `TimelinePinning.apply(to:pinning:)` from Task 1; the view's own existing
  `currentArticleID: String?` property (no new parameter — already threaded in by
  `ReaderHostView`'s `ArticleListView(currentArticleID: ..., onSelect: openArticle)` call).

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/ArticleListFilterTests.swift`, as a new test in the same suite:

```swift
    /// Mirrors `ArticleListView.results`'s browsing-mode chain (no search active): the currently-
    /// open article, even once marked read, must stay ahead of the still-unread rows instead of
    /// jumping to the back of the read block the instant the list is opened.
    @Test func currentArticlePinnedAheadOfReadBlockWhenBrowsing() throws {
        let ctx = try makeContext()
        let feed = Feed(name: "Alpha", aggregator: "feedContent", identifier: "f")
        ctx.insert(feed)
        let a = Article(title: "a", identifier: "a", url: "https://x/a")
        a.date = Date(timeIntervalSince1970: 1); a.feed = feed
        let b = Article(title: "b", identifier: "b", url: "https://x/b")
        b.date = Date(timeIntervalSince1970: 2); b.feed = feed; b.setRead(true)
        let c = Article(title: "c", identifier: "c", url: "https://x/c")
        c.date = Date(timeIntervalSince1970: 3); c.feed = feed
        ctx.insert(a); ctx.insert(b); ctx.insert(c)

        let byTag = TagFilter.apply(to: [a, b, c], disabledTagNames: [], includeUntagged: true)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: [])
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: false)
        let pinned = TimelinePinning.apply(to: canonical, pinning: "b")

        #expect(pinned.map(\.identifier) == ["a", "b", "c"])
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleListFilterTests/currentArticlePinnedAheadOfReadBlockWhenBrowsing`
Expected: FAIL — without the Task 1 change already in place this wouldn't compile; with Task 1 done,
this specific test passes already since it calls `TimelinePinning.apply` directly (this step mainly
confirms the fixture/expectation is right before wiring the view). If it already passes, note that
and proceed — the real regression coverage is `ArticleListView.results` itself, checked in Step 4.

- [ ] **Step 3: Update `ArticleListView.results`**

Replace (current lines 58-67):

```swift
    /// Browsing reads the in-memory index; a search swaps in predicate-fetched results. Both run
    /// through the shared tag/feed filter so the list stays a subset of the reader timeline.
    private var results: [ArticleSummary] {
        let base = searchResults ?? store.summaries
        let byTag = TagFilter.apply(to: base,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        return StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
    }
```

with:

```swift
    /// Browsing reads the in-memory index; a search swaps in predicate-fetched results. Both run
    /// through the shared tag/feed filter so the list stays a subset of the reader timeline. While
    /// browsing (not searching), the currently-open article's row is pinned ahead of the read block
    /// if it's been marked read (see `TimelinePinning`) so opening the list right after finishing an
    /// article doesn't show it jump to the bottom of the read section. Search results are sorted by
    /// date alone (no read/unread blocks to jump between), so pinning is skipped there.
    private var results: [ArticleSummary] {
        let base = searchResults ?? store.summaries
        let byTag = TagFilter.apply(to: base,
                                    disabledTagNames: settings.disabledTagNames,
                                    includeUntagged: settings.includeUntagged)
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        guard searchResults == nil else { return canonical }
        return TimelinePinning.apply(to: canonical, pinning: currentArticleID)
    }
```

- [ ] **Step 4: Run the full test target and build to confirm nothing broke**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleListFilterTests`
Expected: all tests PASS, including the new one from Step 1.

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/ArticleListView.swift YanaTests/ArticleListFilterTests.swift
git commit -m "Pin the open article's position in the article list while browsing"
```

---

### Task 5: Full test run, manual verification, and documentation update

**Files:**
- Modify: `CLAUDE.md` (the **Key patterns → Read state drives the primary sort** section)

**Interfaces:** None — this task only verifies and documents Tasks 1-4's already-complete code.

- [ ] **Step 1: Run the full unit test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: BUILD SUCCEEDED, all tests pass (no regressions introduced by the deleted
`TimelineDisplayOrder` or the protocol change to `TimelineIdentifiable`).

- [ ] **Step 2: Update `CLAUDE.md`'s "Read state drives the primary sort" section**

Find the paragraph starting "**Read state drives the primary sort:**" under **Key patterns** and add
a sentence after the existing "An article is marked read automatically..." sentence:

```markdown
  While the currently-displayed article remains current, its position in every sorted timeline view
  (the iOS reader pager, the Mac sidebar, and the article list's browsing mode) is pinned as if it
  were still unread even after `read` flips to `true` — see `TimelinePinning`
  (`Yana/Utilities/TimelineFiltering.swift`) — so marking it read doesn't visibly reshuffle the list
  out from under the user; it settles into its true read-block position only once the user
  navigates to a different article.
```

- [ ] **Step 3: Manually verify in the iOS Simulator**

Build and run the app in the iOS Simulator (`xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`, then launch via Xcode or `xcrun simctl launch`). With a library containing
several unread articles:
1. Open the reader on an unread article, swipe forward to the next one.
2. Confirm the just-left article does not visibly jump position, and swiping back to it still shows
   it exactly where it was.
3. Open the article list (list button) right after reading an article — confirm that article's row
   is still near where it was, not at the bottom of the read section.
Expected: no visible reshuffling in either the pager or the list.

- [ ] **Step 4: Manually verify on Mac Catalyst, if buildable in this environment**

If Mac Catalyst can be run locally (see `CLAUDE.md`'s Mac Catalyst codesigning notes — this may not
be possible from an agent shell), select an article in the sidebar and confirm it does not jump
position immediately after selection. If Mac Catalyst cannot be run in this environment, note that
explicitly rather than claiming it was verified.

- [ ] **Step 5: Commit the documentation update**

```bash
git add CLAUDE.md
git commit -m "Document TimelinePinning in the read-state-sort key pattern"
```
