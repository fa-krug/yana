# Reader Article List + Settings Restructure — Design

**Date:** 2026-06-19

## Summary

Turn the existing "Library" config hub into two focused surfaces reachable from the reader:

1. A new **article-list sheet** — a second view of the *same* timeline, opened from a button at
   the reader's top-left. It mirrors the reader's active filter, highlights the currently-displayed
   article, and tapping a row jumps the reader to that article.
2. The reader's right-side button stops being a "Library" hub. **Settings moves into the reader's
   overflow (`ellipsis`) menu**, and the Settings screen itself gains a top section linking out to
   the Feeds and Tags lists. The old `ConfigHubView` hub is deleted.

The article list and the reader are "different views of the same thing": one shared timeline, one
shared `AppSettings` filter, one shared selection.

## Motivation

Today the timeline (reader) and the searchable article list live far apart: the list is buried
three taps deep in the Library hub and carries its *own* transient filter, disconnected from the
reader. Users can't quickly scan/jump within the timeline they're reading, and the two filters
diverge confusingly. Promoting the list to a first-class reader surface that shares the reader's
filter and selection makes it a true table-of-contents for the current timeline.

## Current State (baseline)

- **Reader chrome** (`ReaderArticleViewController`):
  - Left bar group: `[filterItem]` (+ `indicatorItem` while refreshing).
  - Right bar group (edge-inward): `[menuItem, library, starItem]` — `library` uses
    `books.vertical` and calls `onShowSettings`, opening `ConfigHubView`.
  - Overflow menu (`buildMenuActions`): Reload, Copy link, Summarize, Go to feed.
- **`ConfigHubView`**: sheet hub linking Feeds, Tags, Articles (`ArticleListView`), Settings.
- **`ArticleListView`**: searchable list with its *own* transient filter (local `@State`:
  `disabledTagNames`/`includeUntagged`/`disabledFeedNames`), presenting `ArticleTagFilterView`.
  Tapping a row pushes `ArticleDetailView`. Keeps swipe actions (star/reload) + swipe-to-delete.
- **Reader timeline filter**: stored in `AppSettings` (`disabledTagNames`/`includeUntagged`/
  `disabledFeedNames`); `ReaderScreen.recomputeFilter()` applies `TagFilter` then `FeedFilter`.
  `TagFilterView` (the AppSettings-backed filter sheet) is what the reader presents.
- **Filter propagation model**: `AppSettings` is `@Observable` over a shared `UserDefaults`, but
  each view instantiates its own `AppSettings()`. Cross-view updates happen because dismissing a
  filter sheet re-renders the presenting view's body, which re-reads the fresh `UserDefaults`
  value (`ReaderScreen` does this via `.onChange(of: settings.disabledTagNames)` etc.). The new
  work follows this same pattern — no live cross-instance observation is introduced.

## Design

### 1. Reader chrome (`ReaderArticleViewController`)

- **Left bar group**: `[articleListItem]` (+ `indicatorItem` while refreshing). The filter button
  leaves the left group.
  - `articleListItem`: `UIBarButtonItem(image: list.bullet)`, accessibility label "Article list",
    action fires a new `onShowArticleList` callback.
  - `setRefreshing` updates the left group between `[articleListItem]` and
    `[articleListItem, indicatorItem]`.
- **Right bar group** (edge-inward array `[menuItem, filterItem, starItem]`): on-screen L→R this
  reads **star · filter · ⋯**, i.e. the filter sits between the star and the overflow menu. The
  former `library`/gear button is removed entirely.
  - `filterItem` keeps its active/inactive icon via the existing `setFilterActive(_:)`.
- **Overflow menu** (`buildMenuActions`):
  - **Add** a **Settings** action (`gearshape`) that fires `onShowSettings`, placed in its own
    trailing section (a separate `UIMenu` appended after the article actions) so it reads as
    app-level, distinct from per-article actions.
  - **Remove** the **Go to feed** action and its branch.
  - Remaining per-article actions: Reload, Copy link, Summarize.

### 2. Article-list sheet (repurpose `ArticleListView`)

`ArticleListView` is repurposed (name kept to minimize churn) into the reader's shared list view.

- **Inputs**: `currentArticleID: String?` and `onSelect: (Article) -> Void`. Presented inside a
  `NavigationStack` as a sheet from `ReaderScreen`.
- **Shared filter**: drop the transient local filter `@State`. Use a `@State AppSettings()` and
  compute results with the *same* pipeline the reader uses, plus the search layer:
  `results = FeedFilter.apply(TagFilter.apply(ArticleSearch.filter(allArticles, debouncedSearch),
  disabledTagNames: settings.disabledTagNames, includeUntagged: settings.includeUntagged),
  disabledFeedNames: settings.disabledFeedNames)`.
- **Filter button**: trailing toolbar item presenting the shared **`TagFilterView`** (AppSettings-
  backed) — replacing `ArticleTagFilterView`. Active/inactive icon driven by
  `settings.isTimelineFilterActive`. Editing the filter here updates the reader too (via the
  sheet-dismiss re-render path).
- **Search**: keep the debounced `.searchable` via `ManagedList`.
- **Swipe actions**: keep star / reload (leading) and swipe-to-delete (with the existing delete
  confirmation dialog).
- **Tap → jump**: rows become `Button`s calling `onSelect(article)` instead of pushing
  `ArticleDetailView`.
- **Highlight + auto-scroll**: the row whose `article.identifier == currentArticleID` gets a
  selected/highlight style; the list scrolls to it on appear (see `ManagedList` change).
- **Close button**: leading (`.cancellationAction`) `xmark`. Title "Articles".
- Keep the existing "stop updating" spinner toolbar affordance.

### 3. `ManagedList` enhancement

Add an optional `scrollToID: Item.ID? = nil`. When non-nil, wrap the inner `List` in a
`ScrollViewReader` and `proxy.scrollTo(scrollToID)` on appear. Backward-compatible: existing
callers (Feeds, Tags) pass nothing and are unchanged.

### 4. Settings screen (`SettingsScreenView`)

- Opened **directly** as a sheet (no hub). `ReaderScreen` presents
  `NavigationStack { SettingsScreenView() }`.
- Add `@Environment(\.dismiss)` and a `.cancellationAction` close (`xmark`) toolbar button.
  `navigationTitle("Settings")` stays.
- **New top section** (above `readerSection`) with `NavigationLink`s to **Feeds** (`FeedsView`)
  and **Tags** (`TagsView`), mirroring the icons/labels the hub used
  (`list.bullet.rectangle`/orange, `tag`/pink).

### 5. Wiring

- **`AppState`**: add `var showArticleList = false`; **remove** `var feedToEdit: Feed?`.
- **`ReaderHostView`** (the `UIViewControllerRepresentable`): add `onShowArticleList` passthrough
  (set in both `makeUIViewController` and `updateUIViewController`); **remove** the `onGoToFeed`
  passthrough.
- **`ReaderScreen`**:
  - Pass `onShowArticleList: { appState.showArticleList = true }`.
  - Add `.sheet(isPresented: $appState.showArticleList) { NavigationStack {
    ArticleListView(currentArticleID: currentArticleID, onSelect: openArticle) } }`, where
    `currentArticleID` is `filteredArticles[safe: appState.currentIndex]?.identifier`.
  - `openArticle(_:)` handler: call `recomputeFilter()` first (so an in-list filter change is
    reflected), resolve the article's index **by identifier** in `filteredArticles`, set
    `appState.currentIndex` and `settings.timelineAnchorIdentifier`, then set
    `appState.showArticleList = false`. Resolving by identifier (not a stale positional index)
    keeps the jump correct even when the filter changed inside the list.
  - Change the settings sheet to `NavigationStack { SettingsScreenView() }`.
  - **Remove** the `goToFeed` handler and the `.sheet(item: $appState.feedToEdit)`.

### 6. Dead-code cleanup

After the tap-behavior change and Go-to-feed removal, these become unreferenced and are removed
(pending a tests/usages check during implementation):

- `ConfigHubView.swift` (replaced by direct Settings + the list button).
- `ArticleDetailView` (only the old `ArticleListView` tap pushed it).
- `ArticleTagFilterView` (only the old `ArticleListView` filter used it).
- `ReaderMenuBuilder`: drop `showGoToFeed` from `ReaderMenuConfig` and the `config(...)` param.
- `onGoToFeed` / `goToFeed` everywhere; `AppState.feedToEdit` and its sheet.
- Any now-orphaned localized strings for the above.

### 7. Translations

Add/keep German (`de`) entries, each `"state": "translated"`, for all new/changed user-facing
strings: "Article list" (accessibility label), "Settings" (overflow menu action), the Feeds/Tags
section labels, and close/accessibility labels. Remove strings orphaned by the cleanup above.

### 8. Tests

- Update/remove tests referencing `ConfigHubView`, `ArticleDetailView`, `ArticleTagFilterView`,
  or `feedToEdit`.
- Add `@MainActor` unit coverage for:
  - The shared results pipeline (search + `TagFilter` + `FeedFilter`) matching the reader's filter.
  - Identifier-based jump resolution: given a selected article, `openArticle` lands on the correct
    index in `filteredArticles` (including after a filter change).
  - `ReaderMenuBuilder.config` no longer exposes Go-to-feed.

## Component boundaries

- **`ArticleListView`** — *what*: render the filtered+searched timeline as a list, report a
  selection and row edits. *Uses*: `currentArticleID`, `onSelect`. *Depends on*: `@Query`,
  `AppSettings` filter, `ArticleSearch`/`TagFilter`/`FeedFilter`, `ManagedList`, `TagFilterView`.
- **`ReaderScreen`** — owns the timeline `@Query`, the shared filter, selection/anchor, and now
  also presents the list + Settings sheets and resolves jumps.
- **`ManagedList`** — gains a one-shot "scroll to this id on appear" capability; otherwise
  unchanged.
- **`SettingsScreenView`** — self-contained settings + a top navigation section to Feeds/Tags.

## Out of scope

- iPad split-view / multi-column layout.
- Any change to aggregation, AI, or notification behavior.
- Persisting the list's scroll position independently from the reader's anchor.
