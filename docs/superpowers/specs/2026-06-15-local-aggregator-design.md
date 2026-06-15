# Local Aggregator Design

## Overview

Yana iOS pivots from a **Google Reader API client** (syncing with a self-hosted Yana
server) to a **self-contained on-device aggregator**. The app fetches, parses, and
processes feeds itself — mirroring the aggregation model of the [Yana server](../Yana) —
and stores everything locally. There is no server, no login, and no network auth.

SwiftData becomes the single source of truth. The existing swipe-through reader stays
the home surface; a new configuration hub is added for managing feeds, groups, articles,
and settings.

## Decisions

- **Architecture:** local-only aggregator. All Google Reader / server-sync code is removed.
- **Aggregator scope:** full parity with the Yana server's aggregator range (RSS/Atom,
  full website, site-specific scrapers, Reddit, YouTube, podcast, AI post-processing).
  Built behind a pluggable protocol/registry; concrete aggregators land incrementally.
- **Persistence:** SwiftData is the single source of truth for feeds, groups, and articles.
- **Settings:** non-secret preferences in `UserDefaults`; secrets (API keys) in Keychain.
- **Aggregator options:** typed `Codable` enum (no opaque JSON blob).
- **Main navigation:** keep the swipe reader as home; add a config hub reachable from a menu.
- **Force update:** three granularities — all feeds, a single feed, a single article.

## Data Layer — SwiftData Models

Three `@Model` classes plus a typed options enum. The `ModelContainer` is created in
`YanaApp` and injected into the environment. Views read via `@Query`.

### `FeedGroup`

- `name: String` — unique
- `sortOrder: Int`
- `createdAt: Date`
- `feeds: [Feed]` — inverse relationship

### `Feed`

Mirrors the Yana server's `Feed`:

- `name: String`
- `aggregatorType: String` — raw value of `AggregatorType`
- `identifier: String` — URL / subreddit / channel id, semantics depend on aggregator
- `dailyLimit: Int` — default 20
- `enabled: Bool` — default true
- `options: AggregatorOptions` — typed Codable config (see below)
- `group: FeedGroup?`
- `articles: [Article]` — inverse relationship, cascade delete
- `lastFetchedAt: Date?`
- `lastError: String?`
- `createdAt: Date`, `updatedAt: Date`

### `Article`

Mirrors the Yana server's `Article`:

- `title: String`
- `identifier: String` — URL or external id; dedup key within a feed
- `url: String` — link to the original article
- `rawContent: String` — raw HTML
- `content: String` — processed HTML rendered in the reader
- `date: Date` — publication date
- `read: Bool`, `starred: Bool`
- `author: String`
- `iconURL: String?`
- `feed: Feed?` — relationship back to the owning feed
- `createdAt: Date`

### `AggregatorOptions` (typed Codable, no blob)

Yana's per-feed `options` are a small, well-defined set per aggregator type (bools / ints
/ strings) plus a shared AI block read by every aggregator. We model this as a typed
`Codable` enum that SwiftData persists as a composite attribute — read `feed.options` as
a real Swift value, no manual JSON, no opaque `Data`.

```swift
enum AggregatorOptions: Codable {
    case fullWebsite(WebsiteOptions)
    case feedContent(FeedContentOptions)
    case reddit(RedditOptions)
    case youtube(YouTubeOptions)
    case podcast(PodcastOptions)
    case managed(ManagedOptions)   // shared shape for site-specific scrapers
}

struct AIOptions: Codable {
    var summarize = false
    var improveWriting = false
    var translate = false
    var translateLanguage = "English"
}
```

Each per-aggregator struct holds that aggregator's known fields with sensible defaults
(e.g. `WebsiteOptions.useFullContent`, `RedditOptions.subredditSort`,
`PodcastOptions.includePlayer`). Every per-aggregator struct embeds an `AIOptions`. The
feed editor UI renders fields by `switch`ing on the enum.

Trade-off accepted: options are not queryable via SwiftData predicates (never needed);
adding a field requires a default (cheap, migration-safe).

## Aggregator System

Mirrors the Yana server's pluggable design so each aggregator is isolated and testable.

- **`enum AggregatorType: String, CaseIterable`** — one case per Yana aggregator:
  `fullWebsite`, `feedContent`, `heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`,
  `caschysBlog`, `mactechnews`, `oglaf`, `meinMmo`, `youtube`, `reddit`, `podcast`.
  Each exposes metadata: `displayName`, `identifierKind` (`.url` / `.subreddit` /
  `.youtubeChannel` / `.none`), `requiredAPIKey` (none / reddit / youtube), and
  `defaultOptions`.
- **`protocol Aggregator`** — `static var type: AggregatorType`;
  `func aggregate() async throws -> [AggregatedArticle]`; `func validate() throws`.
  Built from a `Feed` plus the resolved secrets it needs.
- **`AggregatedArticle`** — plain DTO returned by each aggregator (title, identifier, url,
  rawContent, content, date, author, iconURL). Decoupled from the SwiftData `Article`.
- **`AggregatorRegistry`** — maps `AggregatorType → Aggregator` factory.
- **`AggregationService` (`@MainActor`)** — orchestrates a run. For each enabled `Feed`:
  build its aggregator, `aggregate()`, **upsert** results into SwiftData (dedup by
  `identifier` within the feed), enforce `dailyLimit`, apply the shared **AI
  post-processing** block, then set `lastFetchedAt` / `lastError`. Public API:
  - `updateAll()` — all enabled feeds
  - `update(feed:)` — one feed
  - `update(article:)` — re-fetch and re-process a single article

### Upsert logic

For each `AggregatedArticle`, look up an existing `Article` by `(feed, identifier)`. If
found, update fields (preserving `read` / `starred`); otherwise insert. Idempotent.

## UI Surfaces

The swipe reader remains the home surface; new screens hang off a config hub.

- **Home — swipe reader.** Existing `ArticleReaderView` / `ArticleWebView`, now backed by
  SwiftData `@Query`. Adds:
  - a **scope selector** (All Unread / specific Feed / Group / Starred) driving the query
  - a toolbar **"Update all"** force-refresh button
  - a per-article **force update** action
  - a menu entry into the config hub
- **Config hub** (pushed `NavigationStack`):
  - **Feeds** — grouped list; per row: unread count, `lastFetchedAt`, error badge, enable
    toggle, per-feed force-update; add / delete.
  - **Feed editor** — `name`; `AggregatorType` picker; identifier field whose label/help
    adapts to `identifierKind`; `group` picker; `dailyLimit`; `enabled`; a **dynamic
    options section** rendered by `switch`ing on `AggregatorOptions`; shared **AI options**
    block.
  - **Groups** — add / rename / delete / reorder; reassign feeds.
  - **Article list** — all articles, filterable by feed/group and read/unread/starred; row
    swipe actions for read / star / **force update**; tap jumps into the reader at that
    article; global **"Update all"**.
  - **Settings** — API keys (Reddit id/secret, YouTube key) and AI provider config in
    Keychain; non-secret prefs (active AI provider/model, retention window, background
    interval) in `UserDefaults` via `AppSettings`.

## `AppState`

Becomes a thin UI-state holder:

- Kept: current article index, current **scope** selection, `isUpdating`, `errorMessage`,
  `showSettings`.
- Removed: `isAuthenticated`, `serverURL`, `authToken`, in-memory `articles` / `feeds`,
  `continuation` / `hasMoreArticles`, and all login / data-loading methods.

`AppSettings` (`@Observable`, `UserDefaults`-backed) holds non-secret preferences.

## Settings & Secrets

- **Keychain** (`KeychainService`, repurposed): Reddit client id/secret, YouTube API key,
  AI provider API keys.
- **`UserDefaults`** (`AppSettings`): active AI provider, model selection, AI knobs
  (temperature/limits) as needed, article retention window, background refresh interval.

## Phasing

### Phase 1 — Models (first implementation deliverable)

- New SwiftData models: `Feed`, `FeedGroup`, `Article` (`@Model`).
- `AggregatorOptions` (Codable enum + per-type structs + `AIOptions`).
- Aggregator skeleton: `AggregatorType`, `Aggregator` protocol, `AggregatedArticle`,
  empty `AggregatorRegistry`. No concrete aggregator logic.
- `AppSettings` (`@Observable`, UserDefaults-backed).
- Rework `AppState`; create `ModelContainer` in `YanaApp`; drop the auth gate in
  `ContentView`.
- Delete server files (see below).

### Phase 2 — UI

- Config hub: Feeds list, Feed editor (dynamic options), Groups, Article list, Settings.
- Reader scope selector + update buttons.
- Wired to SwiftData with a stub/no-op `AggregationService`.

### Phase 3 — Aggregation

- Implement `AggregatorRegistry` concretes, in order: `feedContent` (RSS/Atom),
  `fullWebsite`, then managed scrapers, then Reddit / YouTube / podcast, then AI
  post-processing.
- `update(article:)`.
- Best-effort `BGAppRefreshTask` background refresh.

## File Layout

### New files

- `Yana/Models/Feed.swift`, `Yana/Models/FeedGroup.swift`, `Yana/Models/Article.swift`
- `Yana/Models/AggregatorOptions.swift`
- `Yana/Models/AppSettings.swift`
- `Yana/Aggregators/AggregatorType.swift`
- `Yana/Aggregators/Aggregator.swift`
- `Yana/Aggregators/AggregatedArticle.swift`
- `Yana/Aggregators/AggregatorRegistry.swift`
- `Yana/Services/AggregationService.swift` (stub in phase 2, real in phase 3)
- Phase 2 views: `Yana/Views/Config/` (FeedsView, FeedEditorView, GroupsView,
  ArticleListView, SettingsView refactor)

### Modified files

- `Yana/YanaApp.swift` — `ModelContainer`
- `Yana/ContentView.swift` — drop auth gate, open into reader
- `Yana/Models/AppState.swift` — thin UI state
- `Yana/Services/KeychainService.swift` — store API keys
- `Yana/Utilities/Constants.swift` — drop GReader paths
- `CLAUDE.md` — rewrite to the local-aggregator model

### Deleted files

- `Yana/Services/APIClient.swift`
- `Yana/Models/APIModels.swift`
- old value-type `Yana/Models/Article.swift` / `Yana/Models/Feed.swift` (replaced by
  `@Model` versions)
- login/auth UI in `ContentView`

### Kept

- `Yana/Views/ArticleReaderView.swift`, `Yana/Views/ArticleWebView.swift`

## Out of Scope (for now)

- Reconciling with a remote Yana server (no hybrid mode).
- Biometric lock, widgets, notifications, share extension (existing "Enhanced" backlog).
- iPad multi-column split view (reader stays the home surface).
