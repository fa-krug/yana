# Unified Lists — Design

**Date:** 2026-06-16
**Status:** Approved (design)

## Problem

The config hub has three list screens that each expose a different mix of capabilities:

| List | Searchable | Editable | Filter |
|------|-----------|----------|--------|
| `ArticleListView` | ✅ | ❌ (read-only detail) | ❌ |
| `FeedsView` | ❌ | ✅ (add / delete / edit / update) | ❌ |
| `TagsView` | ❌ | ✅ (create / rename / recolor / delete / reorder) | ❌ |

They neither look nor behave consistently, and there is no shared code for the list chrome
(search, swipe-to-delete, empty state).

## Goal

Introduce one **reusable searchable + editable list component** and adopt it across all three
screens so they share a consistent baseline:

- **All three** become searchable and editable (delete at minimum).
- **Articles** additionally gains a **tag filter**.

Non-goals: merging the screens into one, adding star/tag editing to articles, or persisting
the article filter.

## Decisions

- **Unify** = a shared, reusable list component (not a merged screen, not just matching
  behavior by copy-paste).
- **Article "edit"** = swipe-to-delete only (`modelContext.delete` + save). No star/tag editing
  from the list.
- **Article filter** = by **tag**, reusing the timeline's tag set plus an "Untagged" entry.
- The article filter is **independent** of the home timeline's filter — it uses local
  `@State`, never writes to `AppSettings`, and resets to "all on" each time the Articles
  screen opens. It is a transient browsing aid, not a saved preference.

## Architecture — Approach A (generic container)

A new generic container view owns the **common** chrome; each screen keeps its own SwiftData
`@Query` and search/filter state (which must live in the concrete view) and passes already
filtered items in. Screen-specific extras stay as ordinary toolbar/swipe modifiers on each
screen. This gives genuine shared code for the search + edit + empty-state baseline without a
god-component, and plays nicely with `@Query`.

### `Yana/Views/Config/ManagedList.swift`

```swift
struct ManagedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var searchText: String
    var searchPrompt: LocalizedStringKey

    // Search-aware empty state (shown only when items is empty)
    var emptyTitle: LocalizedStringKey
    var emptyIcon: String
    var emptyDescription: LocalizedStringKey

    var onDelete: ((Item) -> Void)? = nil          // nil → no swipe-to-delete
    var onMove: ((IndexSet, Int) -> Void)? = nil   // nil → no reorder (Tags only)

    @ViewBuilder var row: (Item) -> Row
}
```

Behavior:

- Renders `List { ForEach(items) { row($0) } }`.
- Wires swipe-to-delete when `onDelete` is set; wires `.onMove` when `onMove` is set.
- Applies `.searchable(text: $searchText, prompt: searchPrompt)`.
- Overlay empty state: when `items.isEmpty`, show `ContentUnavailableView.search(text:)` if
  `searchText` is non-empty, otherwise the supplied empty config.
- **Reorder + search interaction:** reordering a filtered subset is ambiguous, so `onMove` is
  disabled (no-op / not wired) while `searchText` is non-empty. Reorder is only meaningful on
  the full, unfiltered list. Only Tags uses `onMove`.

## Per-screen changes

### `ArticleListView`

- Adopt `ManagedList`. Keep `@Query(sort: \Article.date, order: .reverse)` and `searchText`.
- New local filter state: `@State disabledTagNames: Set<String>` and
  `@State includeUntagged: Bool` (default: empty set / `true` → all on).
- Items = `TagFilter.apply(ArticleSearch.filter(allArticles, query: searchText),
  disabledTagNames:, includeUntagged:)` — reuses both existing helpers.
- `onDelete`: `modelContext.delete(article)` + `try? modelContext.save()`.
- New **Filter** toolbar button → presents the article filter sheet (Section below). The
  button icon is filled (`line.3.horizontal.decrease.circle.fill`) when any filter is active,
  outline otherwise.
- Tapping a row still opens the read-only `ArticleDetailView`.

### `FeedsView`

- Adopt `ManagedList`. Add `@State searchText` and search.
- Search filters feeds by **name** (case/diacritic-insensitive via `localizedStandardContains`).
- `onDelete` carries the existing delete logic.
- Keep: the per-feed **Update** swipe action (added alongside the component's delete via the
  row), the toolbar (add `+`, **Update All**, OPML import/export menu), and the row chrome
  (disabled badge, error triangle, type / article count / last-fetched, tag chips).

### `TagsView`

- Adopt `ManagedList`. Add `@State searchText` and search.
- Search filters tags by **name**.
- `onDelete`: skip built-in (Starred) tags, delete the rest, save.
- `onMove`: existing reorder, wired through `ManagedList` (auto-disabled while searching).
- Keep: add `+` button, `EditButton`, sheet editor on tap, built-in lock icon.

## Article filter sheet

A small filter sheet (e.g. `ArticleTagFilterView`) driven by **bindings to the Articles
screen's local `@State`** (`disabledTagNames`, `includeUntagged`) — never `AppSettings`.

- Same UI as the timeline's `TagFilterView`: a toggle per tag (`@Query(sort: \Tag.sortOrder)`)
  plus an "Untagged" toggle. All active by default.
- Because it writes to local state, dismissing recomputes the Articles list; it never affects
  the home reader.

## Reuse

- `TagFilter.apply(to:disabledTagNames:includeUntagged:)` — already exists
  (`Yana/Utilities/TimelineFiltering.swift`); reused verbatim for the article filter.
- `ArticleSearch.filter(_:query:)` — already exists; reused for article search.
- Feed/Tag name search uses `localizedStandardContains` inline (trivial; no new helper needed).

## Testing

- `ManagedList` empty-state logic and delete/move wiring are view-level; cover the pure inputs:
  - Article filter composition: `TagFilter.apply(ArticleSearch.filter(...))` returns the
    expected set for combinations of query + disabled tags + includeUntagged (Swift Testing).
  - Feed/Tag name search predicate returns expected matches (case/diacritic-insensitive).
- Existing `ArticleSearch` / `TagFilter` tests remain valid.
- Manual: search + delete on each screen; Tags reorder disabled while searching; article
  filter does not change the timeline filter.

## Localization

All new user-facing strings (search prompts, filter labels, empty-state copy) go through
`String(localized:)` / `LocalizedStringKey` and into `Localizable.xcstrings`.
