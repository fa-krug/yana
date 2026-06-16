# Search + OPML Import/Export + Notifications — Design

**Date:** 2026-06-16
**Status:** Approved (pending spec review)

## Overview

Three user-facing features for Yana iOS, layered onto the completed Phase 4 aggregation
engine. None require a server, network auth, or new platform entitlements.

1. **Article search** — a searchable article list in the configuration hub.
2. **OPML import/export** — standard-OPML feed backup/restore with optional Yana-fidelity
   extension attributes.
3. **New-article notifications** — local notification after a background refresh, **off by
   default**.

These map to the "Enhanced" items in `CLAUDE.md` (Search, Share/portability, Notifications)
and were chosen as the highest-value gaps relative to the Django server
(`../Yana`), which has full-text article search, feed import/export, and email alerts.

---

## 1. Article Search

### Surface
A new **"Articles"** row in `ConfigHubView` (after Feeds/Tags, before Settings), navigating to
a new `ArticleListView`.

### `ArticleListView`
- A `List` of all `Article`s sorted by `date` (reverse), each row showing title, feed name,
  and relative date — mirroring the metadata line in the reader.
- `.searchable(text:)` bound to a `@State` query string.
- The query is applied via a SwiftData `#Predicate` built from the search term. Matching is
  case/diacritic-insensitive (`localizedStandardContains`) OR'd across:
  - `title`
  - `content` (processed HTML — see note)
  - `author`
  - `feed?.name` (to-one relationship traversal)
- Empty query → all articles.
- Empty results → `ContentUnavailableView.search`.
- Implemented as a child view whose `@Query` is constructed in `init(searchText:)` so the
  predicate updates as the term changes (standard SwiftData dynamic-query pattern).

**Note:** `content` is processed HTML; content matches can occasionally hit markup. Acceptable
for v1 — no separate plain-text shadow field (YAGNI). Title/author/feed-name carry most
real-world queries.

### Result navigation
Tapping a row pushes a read-only `ArticleDetailView` **within the config navigation stack**
(not the swipe timeline). Rationale: the reader indexes into the *tag-filtered* timeline and
persists a position anchor; jumping it to an arbitrary search hit fights that logic and breaks
when the hit is hidden by the active filter.

### Shared rendering
Extract the reader's inline article body (title + meta line + `ArticleWebView` + bottom bar
with open-in-browser/share) into a reusable `ArticleContentView`. Both `ArticleReaderView` and
the new `ArticleDetailView` render through it. This is a focused refactor, not a rewrite:
`ArticleReaderView` keeps its swipe/anchor/refresh logic and delegates only the body.

### Files
- New: `Yana/Views/Config/ArticleListView.swift`, `Yana/Views/ArticleDetailView.swift`,
  `Yana/Views/ArticleContentView.swift`.
- Edit: `Yana/Views/Config/ConfigHubView.swift` (add row),
  `Yana/Views/ArticleReaderView.swift` (delegate body to `ArticleContentView`).

---

## 2. OPML Import / Export

### Format
Standard **OPML 2.0**. Each feed becomes an `<outline>` under `<body>`:

```xml
<outline text="Heise" title="Heise" type="rss"
         xmlUrl="https://www.heise.de/rss/heise-atom.xml"
         yana:aggregatorType="heise"
         yana:dailyLimit="20"
         yana:enabled="true"
         yana:tags="Tech,News"
         yana:options="<base64 JSON of AggregatorOptions>" />
```

- `text`/`title` = feed name; `xmlUrl` = feed `identifier` (best standard representation);
  `type="rss"`.
- **Yana extension attributes** (`yana:` namespace declared on `<opml>`): `aggregatorType`,
  `dailyLimit`, `enabled`, `tags` (comma-separated names), `options` (base64-encoded JSON of
  the `AggregatorOptions` enum via its existing `Codable`). Unknown attributes are ignored by
  other OPML readers, so the file remains valid, interoperable standard OPML.

### Components
- **`OPMLCodec`** (pure, no SwiftData): `encode([OPMLFeed]) -> String` and
  `decode(String) -> [OPMLFeed]` where `OPMLFeed` is a plain DTO
  (`name, identifier, aggregatorType?, options?, tags, dailyLimit?, enabled?`). XML parsing via
  `XMLParser`. Fully unit-testable.
- **`FeedPortability`** (thin, `@MainActor`, SwiftData-aware): maps `Feed` ↔ `OPMLFeed`.
  - Export: read all `Feed`s → `[OPMLFeed]` → `OPMLCodec.encode`.
  - Import: `OPMLCodec.decode` → for each DTO:
    - If `aggregatorType` present and valid → restore full feed (decode `options`; if decode
      fails, fall back to that type's `defaultOptions`).
    - Else (foreign OPML) → `feedContent` feed, `identifier = xmlUrl`, default options.
    - Tags: resolve by name (case-insensitive) against existing `Tag`s; create missing ones
      (never duplicate the built-in Starred tag).
    - Dedupe: skip a DTO whose `(identifier, aggregatorType)` already exists. Returns counts
      (imported / skipped) for user feedback.

### UI
In `FeedsView` toolbar:
- **Export**: build OPML string → write to a temp `Yana-Feeds.opml` → present `ShareSheet`.
- **Import**: `.fileImporter` (content types: a custom `.opml` UTType conforming to XML, plus
  plain XML) → read file → `FeedPortability.import` → save → show a brief result
  ("Imported N feeds, skipped M").

### Files
- New: `Yana/Services/OPMLCodec.swift`, `Yana/Services/FeedPortability.swift`.
- Edit: `Yana/Views/Config/FeedsView.swift` (toolbar buttons + importer/exporter state).

---

## 3. New-Article Notifications (off by default)

### Setting
- New `AppSettings.notificationsEnabled` (Bool), registered default **`false`**.
- Surfaced in `SettingsScreenView` under a "Notifications" section: a toggle
  "Notify about new articles".
- Turning it **on** requests `UNUserNotificationCenter` authorization. If the user denies (or
  it's already denied), the toggle reverts to off. Turning it off just clears the flag.

### Service
- **`NotificationService`** wrapping `UNUserNotificationCenter` behind a small protocol
  (`Notifying`) so tests use a fake:
  - `requestAuthorization() async -> Bool`
  - `isAuthorized() async -> Bool`
  - `notifyNewArticles(count:) async` — posts a single local notification with body
    "N new articles" (localized, plural-aware).

### Plumbing — counting new articles
- `ArticleUpsert.apply(...)` returns `Int` = number of **newly inserted** (not updated)
  articles.
- `AggregationService.aggregate(feed:)` returns that per-feed count;
  `updateAll()` and `update(feed:)` return the summed inserted count for the run.
- **Only the background path notifies.** `BackgroundRefreshManager.runRefresh(service:)` (or
  `handle`) takes the count from `updateAll()` and, when
  `notificationsEnabled && authorized && count > 0`, calls
  `NotificationService.notifyNewArticles(count:)`. Foreground/manual refresh (pull-to-refresh,
  "Update All") never notifies — the user is already in the app.

### Platform
Local notifications need no Info.plist usage string and no special entitlement. Authorization
is requested lazily when the user enables the toggle.

### Files
- New: `Yana/Services/NotificationService.swift`.
- Edit: `Yana/Models/AppSettings.swift` (flag + default),
  `Yana/Services/AggregationService.swift` (return counts),
  `Yana/Aggregators/ArticleUpsert.swift` (return inserted count),
  `Yana/Services/BackgroundRefreshManager.swift` (post notification),
  `Yana/Views/Config/SettingsScreenView.swift` (toggle).

---

## Testing (Swift Testing, `@MainActor`)

- **OPMLCodec**: encode→decode round-trip preserves name/identifier/type/options/tags/limit/
  enabled; decoding foreign OPML (no `yana:` attrs) yields `feedContent` DTOs; malformed XML
  fails gracefully.
- **FeedPortability**: import creates feeds + tags, restores options, dedupes existing,
  reports counts; export reflects all feeds (in-memory `ModelContainer`).
- **Article search predicate**: insert fixtures, assert the predicate matches on each of
  title/content/author/feed-name and excludes non-matches.
- **ArticleUpsert**: returns correct inserted count (insert vs update distinguished).
- **AggregationService**: `updateAll()` returns summed inserted count across feeds (fake
  aggregator).
- **Notifications**: gating logic — notifies only when enabled + authorized + count > 0; uses
  a fake `Notifying`. Authorization-revert behavior on denial.

## Out of scope

- Jumping the swipe timeline to a search result (detail view instead).
- Pure-standard-only OPML without Yana attributes (we include them; still valid OPML).
- Per-feed notification grouping (single aggregate "N new articles").
- Plain-text content index for search (search processed HTML directly).
- Read/unread state, multi-library, GReader sync — unchanged architectural decisions.
