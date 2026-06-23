# Unified Background-Loaded Article Store

**Date:** 2026-06-23
**Status:** Approved (design)

## Problem

Opening the searchable article list (`ArticleListView`) is slow. Two independent
causes compound:

1. `ArticleListView` has its **own** `@Query` that materializes whole `Article`
   objects — including the heavy HTML fields (`rawContent`, `content`, potentially
   50KB+ each).
2. The moment a search is active, that query goes **fully unbounded**
   (`limit = nil`) to make full-text search complete — re-fetching the entire
   library with full content on every open.

`ReaderScreen` keeps a *second*, separate `@Query`, so nothing is shared and the
list re-fetches from scratch each time the sheet opens. A `TimelineWindow` system
windows both queries to the newest 100 articles and grows on demand, adding
significant plumbing.

## Goal

Load the article dataset **upfront, in the background**, keep it **in sync** with
everything the reader does, and make the **current-article selection** in the list
clearly visible.

## Design

### 1. New types

**`ArticleSummary`** — a `Sendable` value struct; the lightweight record both
surfaces browse. Carries everything the timeline ordering, filtering, and list row
need — and **no HTML**:

- `persistentID: PersistentIdentifier`
- `identifier: String`
- `title: String`
- `feedName: String`
- `feedLogoHash: String?`
- `author: String`
- `date: Date`
- `createdAt: Date`
- `tagNames: Set<String>`
- `isStarred: Bool`

`content`, `rawContent`, and `summary` never enter the index.

**`ArticleStore`** — `@MainActor @Observable`, the single source of truth:

- `private(set) var summaries: [ArticleSummary]` — chronological (oldest → new),
  the whole library (no windowing).
- `private(set) var hasLoaded: Bool` — drives the timeline skeleton/loading state
  that `@Query` delivery used to drive.
- `func start()` — runs once. Loads the full index via a **background `ModelActor`**
  that fetches `Article` with `propertiesToFetch` (light fields only) and
  `feed` / `tags` prefetched, maps each row to an `ArticleSummary`, and hands the
  array back to the main actor. The dataset thus loads upfront and **off the main
  thread**.
- **Sync:** registers a `ModelContext.didSave` `NotificationCenter` observer. On any
  save (star, delete, feed update, retention cleanup) it re-runs the background
  fetch — debounced/coalesced so a burst of saves during `updateAll()` triggers a
  single refresh — and replaces `summaries`. This keeps the index in sync with
  every mutation the reader or aggregation performs.
- Injected through the SwiftUI environment from `YanaApp` / `ContentView`.

The background fetch uses a `ModelActor` bound to `AppContainer.shared` so it runs
on its own `ModelContext`, producing only `Sendable` `ArticleSummary` values that
cross back to the main actor safely.

### 2. Data flow

- **`ReaderScreen`** drops its own `@Query`. It reads `store.summaries`, applies the
  existing `TagFilter` / `FeedFilter` pipeline (now operating over summaries via
  `tagNames` / `feedName`), and passes `[ArticleSummary]` + `currentIndex` to the
  reader. Anchor save/restore/reanchor logic is unchanged — it already keys off
  `identifier`. The loading/empty/loaded state derives from `store.hasLoaded` +
  filtered count instead of `hasComputedFilter`.
- **`ReaderHostView` / `ReaderArticleViewController`** take `[ArticleSummary]`.
  `makePage(for:)` resolves the full `Article` via an injected
  `resolveArticle: (ArticleSummary) -> Article?` closure
  (`modelContext.model(for: summary.persistentID) as? Article`), then constructs
  `ReaderWebViewController(article:)` exactly as today. The page cache stays keyed
  by `identifier`. `currentArticle()` returns `displayedWebVC?.article`; star /
  share / copy / summarize / reload operate on that live object. Prewarm resolves
  neighbors' full articles by id — one cheap row each. The pager's structure
  (page controller, prewarm plan, LRU cache, fullscreen, memory trim) is otherwise
  untouched to minimize regression risk in this fix-heavy file.
- **`ArticleListView`** drops its `@Query` and `limit` binding. It reads
  `store.summaries`, filters in memory, and renders rows from summaries — so the
  sheet opens **instantly**. Row actions (star / reload / delete) resolve the live
  `Article` by `persistentID` when invoked.

### 3. Search

Browsing reads the in-memory index. While a search query is active, the list runs a
**predicate-backed fetch** (`FetchDescriptor<Article>` with a `#Predicate` matching
`title` / `content` / `author` / `feed.name` against the query) so full-text body
search is preserved. SQLite performs the scan; HTML is never loaded into Swift
memory en masse. Results are mapped to summaries (or rendered directly) and run
through the same `TagFilter` / `FeedFilter` pipeline. This replaces the
"go-unbounded-and-materialize-everything" behavior.

`ArticleSearch` keeps its in-memory matcher for the non-content fields where useful;
the content dimension moves to the predicate path.

### 4. Windowing removed

With a light, fully-loaded index, the `TimelineWindow` system is no longer needed.
Removed:

- `TimelineWindow` usage (the type may be deleted if nothing else references it).
- `ContentView`'s `timelineLimit` state and `onNeedMore` callback.
- `ReaderScreen`'s `limit` / `onNeedMore` / `extendWindowIfNeeded`.
- `ArticleListView`'s `limit` binding / `canLoadMore` / `loadMoreIfNeeded`.
- `ReaderScreen`'s `articleListLimit` state and the unbounded-on-search hack.

Reader and list both show the full set; the pager renders pages lazily as before.

### 5. Selection visibility (list)

The current row gets:

- a **leading accent bar** (slim rounded capsule, full row height),
- a **trailing accent checkmark** (`checkmark` SF Symbol in `accentColor`),
- the existing subtle tinted background retained,
- an accessibility trait / label marking it as the current article.

New user-facing strings are localized to German (`de`) in `Localizable.xcstrings`,
each marked `"state" : "translated"`.

### 6. Testing

- `ArticleSummary` mapping from `Article` (fields, tag names, starred, logo hash).
- `ArticleStore`: initial load populates summaries; `didSave` after insert / star /
  delete is reflected in `summaries` (coalesced refresh).
- Filter pipeline (`TagFilter` / `FeedFilter`) over summaries matches prior behavior.
- Search predicate path returns the same set the old in-memory content search did
  for representative queries.
- Existing reader / anchor / pager tests updated for the `ArticleSummary` type.

## Trade-offs / risks

- The pager refactor touches `ReaderArticleViewController`, the most fix-heavy file
  in the repo. Mitigation: change only the data type and page construction; leave
  the page controller, prewarm, cache, fullscreen, and memory logic intact.
- Removing windowing is a sizable but simplifying diff across `ContentView`,
  `ReaderScreen`, and `ArticleListView`.
- `propertiesToFetch` partial fetches are relied upon to keep HTML unloaded; if a
  given OS build ignores it, correctness is unaffected (heavy fields simply load),
  only the perf benefit is reduced.

## Out of scope

- Reader browsing performance (already acceptable; not the reported symptom).
- Changes to aggregation, retention, or background-refresh logic beyond consuming
  the new `didSave` sync.
