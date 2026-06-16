# Plan: Performance & UX Improvements

Seven independent tasks across three groups (A=performance, B=UX safety/feedback,
C=accessibility/onboarding) for the Yana iOS SwiftUI + SwiftData RSS aggregator.

## Global Constraints

- **Swift 6 strict concurrency.** All UI/SwiftData code is `@MainActor`. SwiftData
  `ModelContext` access must stay on the main actor — never pass a `ModelContext`,
  `@Model` instance (`Feed`, `Article`, `Tag`), or `AppSettings` across an actor boundary
  into a background task.
- **All user-facing strings must be localizable.** Use `String(localized:)` for computed
  strings and `LocalizedStringKey` (plain string literals in SwiftUI `Text`/`Label`) for
  literals. The catalog is `Yana/Resources/Localizable.xcstrings` (auto-extracted by Xcode;
  do not hand-edit it).
- **Match surrounding style.** Follow the existing patterns in each file (doc comments on
  types, `@State`/`@Query` usage, helper-method structure).
- **Tests must pass.** Run `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
  (or scope to the affected test target). Do not break any existing test.
- **No new dependencies.** SwiftUI / SwiftData / Foundation / UIKit only.
- Do not edit `project.yml` or run `xcodegen` unless you add a new source file (new files
  under existing source dirs are picked up automatically by the existing globs — verify by
  building).

---

## Task 1: Concurrent feed fetching in `updateAll()`

**File:** `Yana/Services/AggregationService.swift`

**Problem:** `updateAll()` (line ~79) fetches feeds strictly sequentially:
```swift
for feed in feeds {
    inserted += await aggregate(feed: feed)
}
```
Each feed's network fetch (`aggregator.aggregate()`) and AI processing are awaited before
the next feed starts, so total time is the sum of all feeds. With many feeds this is slow
and risks exceeding the `BGAppRefreshTask` time budget during background refresh.

**Goal:** Run the per-feed work concurrently with a **bounded** concurrency limit so the
slow network/AI awaits interleave, while keeping all SwiftData access on the main actor.

**Approach (recommended):** Because `aggregate(feed:)` is `@MainActor`, you can run multiple
invocations inside a `withTaskGroup` and their `await` suspension points (network, AI) will
interleave on the main actor — giving real concurrency on the I/O waits while the synchronous
SwiftData reads/writes remain serialized and race-free. Add a bounded concurrency limit
(e.g. a constant `maxConcurrentFeedUpdates = 5`) so a large feed list does not spawn an
unbounded number of simultaneous network requests — add tasks up to the limit, then add the
next as each completes (sliding window), summing the returned insert counts.

Keep `aggregate(feed:)` itself essentially as-is (it already does the right main-actor work).
Only `updateAll()`'s loop changes. `update(feed:)` stays sequential (single feed).

**Critical invariants (existing tests assert these — keep them green):**
- Only enabled feeds are aggregated.
- One feed's failure never aborts the run (failures are isolated, recorded in `feed.lastError`).
- `updateAll()` returns the **total** inserted count summed across feeds.
- `isUpdating` is `true` during the run and `false` after (the `defer` already handles this).
- `cleanupAndSave()` runs once after all feeds complete (not per feed).

**Tests:** `YanaTests/AggregationServiceTests.swift` must pass unchanged. Add at least one
new test that inserts several enabled feeds and asserts the summed insert count and per-feed
article counts are correct under the concurrent path (the existing `FakeAggregator` returns
canned articles with no real network — use it). Optionally add a `FakeAggregator` variant
whose `aggregate()` awaits a tiny `Task.yield()`/sleep to exercise interleaving.

**Out of scope:** Do not change `aggregate(feed:)`'s internal logic, the AI processor, or
`update(feed:)`. Do not introduce a background `ModelContext` or `ModelActor`.

---

## Task 2: Stop double-updating the current feed on pull-to-refresh

**File:** `Yana/Views/ArticleReaderView.swift` (the `refresh(current:)` method, line ~116)

**Problem:**
```swift
private func refresh(current: Article?) async {
    let service = AggregationService(context: modelContext)
    if let current { await service.update(article: current) }
    await service.updateAll()
}
```
`service.update(article:)` re-runs the current article's owning feed, and then
`updateAll()` re-runs that same feed again — so the current feed is fetched twice and
`cleanupAndSave()` runs twice per pull-to-refresh.

**Goal:** Pull-to-refresh should update the whole timeline exactly once, with each feed
fetched at most once. Replace the body with a single `await service.updateAll()` call (which
already includes the current article's feed since it is enabled). Remove the now-unused
`current` handling if it leaves the parameter unused — if so, simplify the signature to
`refresh()` and update the call site (`.refreshable { await refresh() }` at line ~58).

Verify `AggregationService.update(article:)` has no other callers before considering whether
it is now dead (do NOT delete it — it is public API used elsewhere/tests; only stop calling
it from here).

**Tests:** No unit test covers this view method directly. Build the app and confirm it
compiles. Manually reason through: after the change, one pull triggers exactly one
`updateAll()`.

**Out of scope:** Any change to `AggregationService`.

---

## Task 3: Confirmation before deleting feeds and tags

**Files:** `Yana/Views/Config/FeedsView.swift`, `Yana/Views/Config/TagsView.swift`

**Problem:** Deleting a feed (swipe action, FeedsView line ~24) or a tag (`onDelete`,
TagsView line ~29) happens immediately with no confirmation. Deleting a feed also discards
its articles. This is an easy accidental data loss.

**Goal:** Add a confirmation step before the actual delete in both views.

- **FeedsView:** When the user taps the destructive "Delete" swipe button, present a
  `confirmationDialog` (or `alert`) asking to confirm. Include the feed name and its article
  count in the message, e.g. message `"Delete “\(feed.name)”? Its \(feed.articles.count) articles will be removed."`
  with a destructive "Delete" button and a "Cancel" button. Perform the existing
  `modelContext.delete(feed); try? modelContext.save()` only on confirm. Track the
  pending-delete feed in a `@State` (e.g. `@State private var feedToDelete: Feed?`).
- **TagsView:** Same pattern for `onDelete`. Built-in tags are already skipped (the `guard
  !tag.isBuiltIn` in `delete`). Only prompt when there is at least one deletable tag in the
  offsets; on confirm, run the existing delete logic. Track pending offsets/tag in `@State`.

Keep all confirmation copy localizable. Match the existing alert pattern already used in
FeedsView (the import-message `.alert(...)`).

**Tests:** No direct unit test for these views; build and confirm compilation. Do not over-engineer.

**Out of scope:** Changing what delete does, or adding undo.

---

## Task 4: Surface feed fetch errors

**File:** `Yana/Views/Config/FeedsView.swift`

**Problem:** A feed with `feed.lastError != nil` shows only an orange warning triangle
(line ~93). The actual error text (`feed.lastError`) is never shown, so users cannot tell
why a feed stopped updating.

**Goal:** Make the error discoverable. When a feed has an error, the user should be able to
see the full `feed.lastError` text. Implement by making the warning triangle tappable to
present the message (e.g. an `alert` or `confirmationDialog` showing `feed.lastError`), OR
by showing the error text inline beneath the feed's meta line in a `.foregroundStyle(.orange)`
caption. Choose the inline approach if it fits the existing row layout cleanly; otherwise the
tappable-icon alert. Keep it accessible (the indicator must have a sensible accessibility
label such as `"Update error"`).

Whichever approach: the error text comes straight from `feed.lastError` (already a
`String?`). Do not truncate it to the point of being useless — inline can use `lineLimit` of
2–3 with the full text available via tap if you go inline+tappable.

**Tests:** Build and confirm compilation. No unit test required.

**Out of scope:** Changing how/when errors are recorded in `AggregationService`.

---

## Task 5: Progress and result feedback for feed updates

**File:** `Yana/Views/Config/FeedsView.swift`

**Problem:** `updateAll()` and `updateOne(_:)` (lines ~114–125) run silently. The
`isUpdating` flag only disables buttons; there is no progress indicator and no result. The
user gets no confirmation that an update happened or how many new articles arrived.

**Goal:**
1. **Progress:** While `isUpdating` is true, show a visible in-progress indicator — e.g. a
   `ProgressView` in the toolbar where the "Update All" button is (swap the button for a
   spinner while updating), or an overlay `ProgressView("Updating…")`. The button-disable
   behavior already exists; add the visible spinner.
2. **Result:** `AggregationService.updateAll()` and `update(feed:)` both return the count of
   newly inserted articles (`@discardableResult Int`). Capture that count and show a transient
   result message reusing the existing `importMessage`/`.alert` mechanism (or a dedicated
   `@State` message): e.g. `"Added \(count) new articles."` and for a single feed
   `"Added \(count) new articles from \(feed.name)."` Use a pluralization-friendly localized
   string. If `count == 0`, show `"No new articles."`.

Keep it simple and consistent with the existing alert pattern in the file. All strings localizable.

**Tests:** Build and confirm compilation. No unit test required (the service already has
return-count tests).

**Out of scope:** Surfacing per-feed failure detail (Task 4 covers error display); AI
progress.

---

## Task 6: Accessibility — toolbar labels and Dynamic Type in the reader

**Files:** `Yana/Views/ArticleReaderView.swift`, `Yana/Views/ArticleContentView.swift`

**Problem:**
- The reader toolbar buttons use bare `Image(systemName:)` with no accessibility labels
  (ArticleReaderView lines ~61, ~65–70, ~74): filter, star, settings. VoiceOver announces
  only "button".
- `ArticleContentView` uses `.font(.title2.bold())` for the title which respects Dynamic
  Type, but verify nothing in the visible SwiftUI chrome is a hardcoded fixed-point font.
  (The WebView CSS font is out of scope — handled by the web content, not SwiftUI.)

**Goal:**
1. Add `.accessibilityLabel(...)` to each reader toolbar button with a clear localized label:
   filter button → `"Filter articles"`, star button → a dynamic label reflecting state
   (`article.isStarred ? "Unstar article" : "Star article"`), settings/gear button →
   `"Settings"`. Also consider the bottom-bar buttons in `ArticleContentView`
   ("Open in Browser", "Share") — those already use `Label` with text so they have implicit
   labels via `.labelStyle(.iconOnly)`; confirm VoiceOver still reads the label text (it does
   for `Label`), so no change needed there unless you find a gap.
2. Confirm SwiftUI text in `ArticleContentView` uses semantic fonts (`.title2`, `.subheadline`,
   etc.) that scale with Dynamic Type — they already do; make no change unless you find a
   fixed `.system(size:)` font. Do NOT touch the `ArticleWebView` HTML/CSS.

Keep all labels localizable.

**Tests:** Build and confirm compilation. No unit test required.

**Out of scope:** WebView CSS / Dynamic Type inside rendered HTML; VoiceOver image alt text;
haptics.

---

## Task 7: First-feed onboarding in the empty reader state

**File:** `Yana/Views/ArticleReaderView.swift`

**Problem:** The empty-timeline state (lines ~44–50) tells the user to "Add feeds in
Configuration, then pull down to refresh," but the gear/Configuration entry point is an
unlabeled toolbar icon opening a sheet — not obvious to a first-time user.

**Goal:** Add a primary action button to the `ContentUnavailableView` empty state that opens
the configuration hub directly, e.g. an "Add Your First Feed" button whose action sets
`appState.showSettings = true` (the existing sheet at line ~77 presents `ConfigHubView`).
Use the `ContentUnavailableView { label } description: { ... } actions: { Button(...) }`
form. Keep the existing label/description; just add the actions closure with the button.
String localizable. (Task 6 adds the gear accessibility label separately; this task is about
the empty-state CTA.)

**Tests:** Build and confirm compilation. No unit test required.

**Out of scope:** A multi-step onboarding flow; changing `ConfigHubView`.
