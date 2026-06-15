# Local Aggregator Design

## Overview

Yana iOS pivots from a **Google Reader API client** (syncing with a self-hosted Yana
server) to a **self-contained on-device aggregator**. The app fetches, parses, and
processes feeds itself — mirroring the aggregation model of the [Yana server](../Yana) —
and stores everything locally. There is no server, no login, and no network auth.

SwiftData is the single source of truth. The home surface is a **single endless timeline**
of all articles that the user swipes through in both directions; the app remembers the
position. A configuration hub manages feeds, tags, and settings.

The reading model deliberately diverges from the server: **there is no read/unread state**,
feeds are organized with **tags** (not groups), and **"Starred" is itself a built-in tag**.

## Decisions

- **Architecture:** local-only aggregator. All Google Reader / server-sync code is removed.
- **Aggregator scope:** full parity with the Yana server's aggregator range (RSS/Atom,
  full website, site-specific scrapers, Reddit, YouTube, podcast, AI post-processing).
  Built behind a pluggable protocol/registry; concrete aggregators land incrementally.
- **Persistence:** SwiftData is the single source of truth for feeds, tags, and articles.
- **No read/unread state.** Articles are imported and read by swiping the timeline; the only
  per-article user state is membership of the built-in **Starred** tag.
- **Tags, not groups.** Feeds carry a set of tags. Tags are **snapshotted onto each article
  at import time** — adding a tag to a feed does *not* retroactively tag existing articles;
  only articles imported (or reloaded) afterward receive the new tag set.
- **Settings:** non-secret preferences in `UserDefaults` (`AppSettings`); secrets (API keys)
  in Keychain. Full parity with the server's `UserSettings` (per-provider AI config + knobs).
- **Aggregator options:** typed `Codable` enum (no opaque JSON blob), one case per
  aggregator type, including per-scraper option structs.
- **Main navigation:** the endless swipe timeline is home; a config hub is reachable from a
  menu.
- **Force update:** a **pull-down gesture** on the reader force-updates the current article
  *and* the whole timeline. Per-feed and all-feeds updates are also available in the config
  hub.

## Data Layer — SwiftData Models

Four `@Model` classes plus a typed options enum. The `ModelContainer` is created in
`YanaApp` and injected into the environment. Views read via `@Query`.

### `Tag`

- `name: String` — unique
- `colorHex: String?` — optional display color
- `isBuiltIn: Bool` — `true` only for the seeded **Starred** tag (locked: cannot be deleted
  or renamed; may be recolored)
- `sortOrder: Int`
- `createdAt: Date`
- `feeds: [Feed]` — inverse (many-to-many template association)
- `articles: [Article]` — inverse (many-to-many; the actual tags carried by articles)

A single built-in **Starred** tag is seeded on first launch.

### `Feed`

Mirrors the Yana server's `Feed` (minus groups):

- `name: String`
- `aggregatorType: String` — raw value of `AggregatorType`
- `identifier: String` — URL / subreddit / channel id, semantics depend on aggregator
- `dailyLimit: Int` — default 20
- `enabled: Bool` — default true
- `options: AggregatorOptions` — typed Codable config (see below)
- `tags: [Tag]` — **template** tags applied to articles at import time (many-to-many)
- `articles: [Article]` — inverse relationship, cascade delete
- `lastFetchedAt: Date?`
- `lastError: String?`
- `createdAt: Date`, `updatedAt: Date`

### `Article`

Mirrors the Yana server's `Article` (no read state):

- `title: String`
- `identifier: String` — URL or external id; dedup key within a feed
- `url: String` — link to the original article
- `rawContent: String` — raw HTML
- `content: String` — processed HTML rendered in the reader
- `date: Date` — publication date; the timeline orders by this
- `tags: [Tag]` — snapshot of the owning feed's tags at import time, plus the **Starred** tag
  when the user stars the article (many-to-many)
- `author: String`
- `iconURL: String?`
- `feed: Feed?` — relationship back to the owning feed
- `createdAt: Date`

**Starred** is expressed purely as membership of the built-in Starred tag in `tags` — there
is no separate boolean. Starring toggles that tag on the article.

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
    // Per-scraper cases — each exposes only the fields that scraper actually reads:
    case heise(HeiseOptions)
    case merkur(MerkurOptions)
    case tagesschau(TagesschauOptions)
    case explosm(ExplosmOptions)
    case darkLegacy(DarkLegacyOptions)
    case caschysBlog(CaschysBlogOptions)
    case mactechnews(MactechnewsOptions)
    case oglaf(OglafOptions)
    case meinMmo(MeinMmoOptions)
}

struct AIOptions: Codable {
    var summarize = false
    var improveWriting = false
    var translate = false
    var translateLanguage = "English"
}
```

Each per-aggregator struct holds that aggregator's known fields with sensible defaults and
embeds an `AIOptions`. The fields mirror the server's `get_configuration_fields()` exactly:

| Type | Fields (defaults) |
|---|---|
| `WebsiteOptions` | `useFullContent` (true), `customContentSelector` (""), `customSelectorsToRemove` ("") |
| `FeedContentOptions` | *(AI only — no extra fields)* |
| `RedditOptions` | `subredditSort` ("hot"), `minComments` (5), `commentLimit` (10), `includeHeaderImage` (true), `minAgeHours` (48, 0–168) |
| `YouTubeOptions` | `commentLimit` (10) |
| `PodcastOptions` | `includePlayer` (true), `includeDownloadLink` (true), `artworkSize` (300) |
| `HeiseOptions` | `includeComments` (true), `maxComments` (5) |
| `MerkurOptions` | `removeEmptyElements` (true) |
| `TagesschauOptions` | `skipLivestreams` (true), `skipVideos` (true) |
| `ExplosmOptions` | `showAltText` (true) |
| `DarkLegacyOptions` | `showAltText` (true) |
| `CaschysBlogOptions` | `skipAds` (true) |
| `MactechnewsOptions` | `combinePages` (true), `includeComments` (true), `maxComments` (5) |
| `OglafOptions` | `showAltText` (true), `convertToBase64` (true) |
| `MeinMmoOptions` | `combinePages` (true) |

The feed editor UI renders fields by `switch`ing on the enum, so each feed type shows only
its relevant controls plus the shared AI block.

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

For each `AggregatedArticle`, look up an existing `Article` by `(feed, identifier)`.

- **Insert:** create the article and set `article.tags = feed.tags` (a snapshot of the
  feed's current tags).
- **Update:** refresh content fields. Recompute tags as `feed.tags` **plus the Starred tag
  if the article currently carries it** — i.e. feed-derived tags are re-snapshotted while the
  user's star survives a reload.

Idempotent; the only preserved user state across a reload is the Starred tag.

## UI Surfaces

The endless swipe timeline is the home surface; configuration hangs off a config hub.

- **Home — endless timeline.** `ArticleReaderView` backed by a SwiftData `@Query` of all
  articles ordered by `date` descending. Adds:
  - **Identity-based position memory** — the current article's anchor (`identifier` + `date`)
    is persisted; on launch the reader restores to it. Newly imported articles prepend at the
    newest end without moving the user's spot. If the anchored article was cleaned up (or is
    filtered out), snap to the nearest visible article.
  - **Pull-down to refresh** — a top→bottom pull gesture force-updates the current article
    (`update(article:)`) *and* the whole timeline (`updateAll()`).
  - **Tag filter button** — opens a list of **all tags plus an "Untagged" entry**, each a
    toggle, **all active by default**. OR semantics: an article shows if any of its tags is
    active; articles with no tags show while "Untagged" is on. The active filter is persisted.
  - **Star toggle** on the current article (adds/removes the Starred tag).
  - a menu entry into the config hub.
- **Config hub** (pushed `NavigationStack`):
  - **Feeds** — flat list; per row: tag chips, `lastFetchedAt`, error badge, enable toggle,
    per-feed force-update, article count; add / delete; an "Update all" action.
  - **Feed editor** — `name`; `AggregatorType` picker; identifier field whose label/help
    adapts to `identifierKind`; **tag multi-select with inline create**; `dailyLimit`;
    `enabled`; a **dynamic options section** rendered by `switch`ing on `AggregatorOptions`;
    shared **AI options** block.
  - **Tags** — create / rename / recolor / delete / reorder. The built-in Starred tag is
    locked (recolor only).
  - **Settings** — Reddit (client id/secret/user-agent/enabled), YouTube (key/enabled), and
    AI provider config (active provider; per-provider enabled/key/model; OpenAI custom URL;
    AI knobs) — secrets in Keychain, non-secret prefs in `AppSettings`. Plus retention window
    and background interval.

## `AppState`

A thin UI-state holder:

- Kept: timeline anchor (current article identity), active tag-filter selection, `isUpdating`,
  `errorMessage`, `showSettings`.
- Removed: `isAuthenticated`, `serverURL`, `authToken`, in-memory `articles` / `feeds`,
  `continuation` / `hasMoreArticles`, login / data-loading methods, and the `Scope` enum
  (there is no per-feed/group scope — the timeline is global, filtered only by tags).

`AppSettings` (`@Observable`, `UserDefaults`-backed) holds non-secret preferences.

## Settings & Secrets

Full parity with the server's `UserSettings`.

- **Keychain** (`KeychainService`): Reddit client id/secret, YouTube API key, and the
  OpenAI / Anthropic / Gemini API keys.
- **`UserDefaults`** (`AppSettings`):
  - **Sources:** `redditEnabled`, `redditUserAgent` (default `"Yana/1.0"`), `youtubeEnabled`.
  - **AI providers:** `activeAIProvider` (none / openai / anthropic / gemini); per-provider
    `…Enabled` and `…Model`; `openaiAPIURL` (default `https://api.openai.com/v1`).
  - **AI knobs:** `aiTemperature` (0.3), `aiMaxTokens` (2000), `aiMaxPromptLength` (500),
    `aiDefaultDailyLimit` (200), `aiDefaultMonthlyLimit` (2000), `aiRequestTimeout` (120),
    `aiMaxRetries` (3), `aiRetryDelay` (2), `aiRequestDelay` (2).
  - **Library:** `retentionDays` (default 30 — "keep ~one month"), `backgroundInterval`.
- **Model lists:** iOS maintains its own up-to-date per-provider model lists in code (the
  server's choice lists are stale); easily updated as providers ship new models.

## Phasing

### Phase 1 — Models (complete) ⚠️ revised in Phase 2

- New SwiftData models and the aggregator skeleton landed in Phase 1. Phase 2 **revises**
  them to this design: introduce `Tag`, drop `FeedGroup`, drop `Article.read` and the
  `starred` boolean, add `tags` to `Feed`/`Article`, split `ManagedOptions` into per-scraper
  structs, add `RedditOptions.minAgeHours` / `OglafOptions.convertToBase64`, drop
  `FeedContentOptions.fetchFullContent`, and expand `AppSettings` to full parity. (Phase 1
  is merged but unreleased, so this is plain model evolution — no user-data migration.)

### Phase 2 — UI

- Config hub: Feeds list, Feed editor (dynamic options + tag multi-select), Tags, Settings.
- Endless timeline reader: identity-based position memory, pull-down to refresh, tag filter.
- Wired to SwiftData with a stub/no-op `AggregationService`.

### Phase 3 — Aggregation

- Implement `AggregatorRegistry` concretes, in order: `feedContent` (RSS/Atom),
  `fullWebsite`, then managed scrapers, then Reddit / YouTube / podcast, then AI
  post-processing.
- Real upsert with tag snapshotting (preserve Starred), daily-limit, age-based retention
  cleanup (delete articles older than `retentionDays` **except** those tagged Starred).
- `update(article:)`.
- Best-effort `BGAppRefreshTask` background refresh.

## File Layout

### New files

- `Yana/Models/Tag.swift`, `Yana/Models/Feed.swift`, `Yana/Models/Article.swift`
- `Yana/Models/AggregatorOptions.swift`
- `Yana/Models/AppSettings.swift`
- `Yana/Aggregators/AggregatorType.swift`
- `Yana/Aggregators/Aggregator.swift`
- `Yana/Aggregators/AggregatedArticle.swift`
- `Yana/Aggregators/AggregatorRegistry.swift`
- `Yana/Services/AggregationService.swift` (stub in phase 2, real in phase 3)
- Phase 2 views under `Yana/Views/Config/` (FeedsView, FeedEditorView, AggregatorOptionsForm,
  TagsView, SettingsScreenView)

### Modified files

- `Yana/YanaApp.swift` — `ModelContainer` (register `Tag`; seed Starred)
- `Yana/ContentView.swift` — drop auth gate, open into the timeline reader
- `Yana/Models/AppState.swift` — thin UI state (anchor + tag filter)
- `Yana/Services/KeychainService.swift` — store API keys
- `Yana/Utilities/Constants.swift` — drop GReader paths
- `CLAUDE.md`, `README.md` — local-aggregator + tags + timeline model

### Deleted files

- `Yana/Models/FeedGroup.swift` (replaced by `Tag`)
- `Yana/Services/APIClient.swift`
- `Yana/Models/APIModels.swift`
- old value-type `Yana/Models/Article.swift` / `Yana/Models/Feed.swift` (replaced by
  `@Model` versions)
- login/auth UI in `ContentView`

### Kept

- `Yana/Views/ArticleReaderView.swift`, `Yana/Views/ArticleWebView.swift`

## Out of Scope (for now)

- Reconciling with a remote Yana server (no hybrid mode).
- Read/unread state (intentionally dropped).
- Arbitrary per-article tagging beyond the built-in Starred tag (tags otherwise come from
  feeds).
- Biometric lock, widgets, notifications, share extension (existing "Enhanced" backlog).
- iPad multi-column split view (the timeline stays the home surface).
