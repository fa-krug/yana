# Rework Yana iOS/Mac as a yana-server API Client

**Date:** 2026-08-05
**Status:** Draft, pending user review
**Related:** [2026-08-04-pre-server-migration-notice-design.md](2026-08-04-pre-server-migration-notice-design.md)
(that spec explicitly scoped this integration out — "pairing, auth, sync... separate, much larger
effort tracked in the 2.0.0 milestone itself." This is that effort.)

## Problem

Yana iOS/Mac is currently a fully self-contained, on-device RSS/content aggregator: it fetches,
parses, and AI-post-processes feeds itself, and stores everything in a local (post-CloudKit-removal,
single-device) SwiftData store. A companion server, `yana-server`
(`/Users/skrug/PycharmProjects/yana-server`), now exists with a purpose-built REST+SSE API
("Phase 13 — Client API") designed specifically for this app: device-pairing auth, delta sync with
tombstones, per-feed aggregation triggering, and content already rendered into the same `[Block]`
wire format the iOS reader uses. The 1.x on-device aggregation/AI/credential-management code is now
redundant with what the server does, and duplicating both is not sustainable.

## Goal

Rework the app so it uses **only** `yana-server`'s `/api/v1` for content: sign-in, sync, read
article bodies, star, trigger updates/reloads, and fetch images/logos. Feed/tag/settings management
— which the server only exposes through its own web UI, not the client API — moves into an
in-app WebView rather than being reimplemented natively. All on-device aggregation, scraping, and
cloud-AI-provider code is deleted, not kept as a fallback.

## Decisions

| Decision | Choice |
| --- | --- |
| Feed/tag/settings management | In-app WebView hosting the server's existing web UI (reuses the pairing session's cookies). No new native CRUD screens, no new server write endpoints. |
| AI processing | Exactly two app-wide modes: **Server** (per-feed summarize/improve/translate run automatically server-side, edited via the WebView; iOS renders the result as-is) and **Apple Intelligence** (on-device, kept from the existing implementation, re-sourced from server-synced raw content). The 6 cloud bring-your-own-key providers (OpenAI/Anthropic/Gemini/Mistral/Qwen/DeepSeek) are removed from iOS entirely. |
| AI summary block (Server mode) | Implemented via `POST /api/v1/ai/prompt` (now shipped — generic free-form prompt run against the user's server-configured provider, JSON response, rate-limited). Both modes produce the summary block; only the execution path differs (network call vs on-device Foundation Model). |
| Local persistence | Kept, and **offline-first**: SwiftData remains a full local mirror — not just article summaries but every article's full `[Block]` content and every referenced image/logo, eagerly pulled during sync rather than fetched lazily on render. Preserves `ArticleStore` and the endless timeline as-is; the reader never needs network for anything already synced. |
| Search | Unaffected. `ArticleSearch` keeps matching title/content/author/feed name exactly as today — safe only because content is eagerly synced (see Local persistence); this would have silently regressed under a lazy-fetch design. |
| Starred | Becomes a plain `Article.starred: Bool`, synced via `PATCH /articles/:id`, replacing the built-in "Starred" tag / `StarredRegistry`. UI (a Starred filter chip) is unchanged in appearance. |
| Tag filtering | Becomes live (joined from `Feed.tagIds` at display time each sync) instead of snapshotted onto each article at import. Accepted behavior change — matches the server's live many-to-many model. |
| `read` field | Present on the wire, intentionally unused. Preserves the existing "no read/unread state" product decision; the field is decoded but never acted on or written. |
| Images and feed logos | Both eagerly downloaded by content hash via `GET /api/v1/images/:hash` as part of the sync pass (not fetched lazily on render — see Local persistence), into a reworked `ImageStore` disk cache. The CloudKit-era `StoredImage`/`ImageSync`/`StoredImageRegistrar` bridge (already dead weight since CloudKit's removal) is deleted outright, not adapted. Client-side recompression/background-removal (`ImageCompressor`, `LogoBackgroundRemover`) is deleted — the server already stores final, processed bytes. The existing 64 MB response cap (`HTTPClient.maxImageResponseBytes`, raised specifically for large Reddit GIFs) carries over into the new fetch path — the server doesn't enforce an equivalent cap itself. |
| OPML import/export | Dropped entirely (`FeedPortability`, `OPMLCodec`). No server equivalent exists; feed management no longer happens natively. |
| Reddit/YouTube credentials | Dropped from iOS Keychain/Settings/`CredentialTester`. Configured server-side via the WebView. |
| Retention | Server-side only (`user_settings.articleRetentionDays`). Local retention job and `ImagePrune`'s quarantine logic are removed; the local cache instead mirrors whatever the server's tombstones say to remove. |
| Existing local data on sign-in | Fresh start, per the server's own designed assumption — no import path. Acceptable given the pre-2.0 migration notice already told upgrading users the architecture is changing. |
| Onboarding (`WelcomeView`) | Exactly three steps: welcome/feature highlights → server configuration (base URL entry + device-pairing login) → AI mode choice (Server / Apple Intelligence). The old third step (create-a-first-feed) is removed — there is no native feed creation to onboard into. |
| Mac Catalyst | Same rework. `MacSettingsWindow`'s Feeds/Tags/AI/Integrations panes become WebView-hosted; `MacRootView`'s reader/sidebar/timeline stay native, reading from the same sync-backed `ArticleStore`. |
| Background refresh | `BGAppRefreshTask` calls `/api/v1/articles/sync` directly instead of running local aggregation. |
| Notifications | Unchanged mechanism (local notification with new-article count after a background refresh), now driven by the sync result's `new` count instead of `AggregationService`'s insert count. |

## Architecture

### Auth: device pairing

A new `Yana/Services/DevicePairing.swift` (or similar) drives the flow the server was designed
around:

1. App generates a random `state`, keeps it only in memory.
2. Opens a **persistent** (non-ephemeral `WKWebsiteDataStore`, so cookies survive across launches)
   `WKWebView` at `<serverURL>/login?next=/device/pair?state=<state>&scheme=yana&deviceName=<name>`.
3. User logs in exactly as on the web (password or passkey) — no passkey/session logic is
   reimplemented natively.
4. The server's `/device/pair` mints a new session and redirects to
   `yana://auth-callback?token=<sessionToken>&state=<echoed>`.
5. A `WKNavigationDelegate` intercepts that custom-scheme navigation before it becomes a network
   request, verifies the echoed `state` matches, and stores the token in Keychain
   (`KeychainService` gains a `deviceSessionToken` entry; the 6 removed AI-provider keys and the
   Reddit/YouTube keys are deleted from it in the same pass).
6. Every `/api/v1/**` request thereafter carries `Authorization: Bearer <token>`.

**Net-new requirement, not something to assume already exists**: the app registers no custom URL
scheme today (checked `project.yml`/Info.plist — no `CFBundleURLTypes` at all). Handling
`yana://auth-callback` requires adding a URL type to `project.yml` and, since it's intercepted
inside the pairing `WKWebView`'s navigation delegate rather than via system `onOpenURL`, that
registration exists mainly so the OS never treats an accidental top-level navigation to `yana://`
as "no app can open this."

The server's base URL is a new per-device setting (this is self-hosted software — there is no
fixed host), entered during onboarding's server-configuration step and editable later in Settings.
The same persistent `WKWebView`/cookie store is reused for the management WebView (see below), so a
user who just paired doesn't have to log in again to reach feed/tag/settings pages.

### Networking + sync engine

New `Yana/Networking/` module:

- `YanaAPIClient` — thin typed wrapper over `URLSession` for every `/api/v1/**` route: `GET
  /articles/sync`, `PATCH /articles/:id`, `GET /articles/:id/content`, `POST
  /articles/:id/reload`, `POST /aggregate`, `GET /runs/:id`, `GET /jobs/events` (SSE), `GET
  /feeds`, `GET /tags`, `GET /images/:hash`. Attaches the Bearer token; surfaces the server's
  `{ error: { code, message } }` envelope as a typed error.
- `SyncEngine` — replaces `AggregationService`'s write path, and is **offline-first**: a sync pass
  fully replicates the server's article set — summaries, full block content, and every referenced
  image — into the local store, not just metadata. Holds the opaque sync cursor (persisted
  device-locally, not synced — it's per-device network state, same tier as `UpdateInterval`). One
  pass:
  1. Calls `/articles/sync?cursor=...`, looping (using the `limit` param, 1-500) until a response's
     `new`/`updated` no longer fills a full page — i.e. catches all the way up to head in one pass.
     This matters most on the **first sync after pairing**, which can return the account's entire
     retained history (default 60 days) rather than a small delta.
  2. Upserts each `new`/`updated` article's summary into SwiftData (`createdAt` preserved on
     update, matching today's "re-fetched articles keep their original `createdAt`" rule), then
     fetches its full content (`GET /articles/:id/content`) at bounded concurrency (a handful of
     concurrent requests via a task group, not one-at-a-time and not unbounded) and writes the
     decoded `[Block]`s alongside it.
  3. Parses each fetched article's blocks (plus every `Feed.logoImageHash`) for `yana-img://<hash>`
     refs, and fetches (`GET /images/:hash`, same bounded-concurrency pattern) any hash not already
     on disk.
  4. Applies `removed` deletions.
  5. On `{ resyncRequired: true }`, drops the stored cursor and re-pulls from scratch (equivalent to
     today's full re-read fallback in `SummaryIndexMerge`).
  - **Partial-failure bookkeeping**: the sync cursor advances once a page's summaries are applied,
    independent of whether every content/image fetch in that page succeeded — a dropped connection
    mid-sync must not block progress or re-fetch things already obtained. An article whose content
    (or an image it references) failed to download is marked with a local-only
    `needsContentBackfill`/`needsImageBackfill` flag, retried opportunistically on the next sync or
    app-foreground event (not by re-calling `/articles/sync`, which won't re-list an article the
    cursor has already passed).
  - `ArticleBlockView`'s `yana-img://` resolution and the reader's content lookup still check the
    disk cache / local `[Block]` column first, exactly as before; a network fetch-on-miss stays as a
    safety net for a not-yet-completed backfill item, not the primary path.

**First-sync UX**: since a fresh pairing's initial pass can be sizeable (full retained history,
every article's content and images), the app shows a "Syncing your library…" progress state
(counts, not just a spinner) after pairing succeeds, rather than dropping straight into the
timeline. Background refresh (`BGAppRefreshTask`) runs the same pass under the OS's time budget;
whatever it can't finish in that window is left for the backfill queue rather than blocking.

`ArticleStore` keeps its role (in-memory `ArticleSummary` index, incremental splice on save) — only
what feeds it changes, from `AggregationWriter`'s upserts to `SyncEngine`'s upserts. `Feed`/`Tag`
become simple read-through caches of `GET /feeds`/`GET /tags`, refreshed on foreground and
pull-to-refresh (no delta protocol for these — the responses are small and unpaginated).

Actions map directly onto the API:

| iOS action | Call |
| --- | --- |
| Pull-to-refresh / "Update all" | `POST /aggregate`, then poll `GET /runs/:id` (or listen on `/jobs/events`) until done, then `GET /articles/sync` |
| Reader/"Reload" (single article) | `POST /articles/:id/reload`, then re-fetch that article's content once the job completes |
| Star/unstar | `PATCH /articles/:id { starred }` |
| Background refresh | `GET /articles/sync` directly (no need to trigger `/aggregate` — that's for pulling *new* fetches from the source sites, which the server should already be doing on its own schedule; background refresh here is just picking up whatever the server has produced since last sync) |

Note: the old per-feed swipe actions ("Update" one feed, "Reload" a whole feed) lived on
`FeedsView`, which is removed entirely (feed management moves to the WebView per the decision
above) — there is no native surface left for them, and `/aggregate` only supports "run every
enabled feed" anyway, so no native replacement is needed.

### Data model changes

- `Article.starred: Bool`, written via `SyncEngine`'s upsert and `PATCH`. `StarredRegistry` and the
  built-in "Starred" `Tag` are removed. `TagFilterView`'s Starred entry becomes a plain boolean
  filter instead of a tag-membership filter.
- `Article.tags` (the old per-article snapshot) is removed. Tag membership for filtering is derived
  at query/display time from `feedId → Feed.tagIds` (from the last `/feeds` fetch), refreshed each
  sync — a live join, not a snapshot.
- `Article.read` is decoded from the sync payload into the model (for forward-compatibility and
  because the column already exists conceptually) but nothing reads or writes it — no unread UI,
  no PATCH call ever sends it.
- `Feed.logoImageHash` replaces the old file-path `logo` column, synced from `/feeds`.
  `Feed.aggregator` becomes a plain, unvalidated `String` (display-only — nothing client-side
  branches on aggregator type anymore, since there's no native feed creation/editing left to
  special-case). The `AggregatorType` enum is deleted.
- `ArticleUID` and `ArticleSummary.uid` are deleted, not ported. They already only serve
  `AggregationWriter`/`ArticleUpsert`/`RetentionCleanup`/`LibraryDedup` — all removed in this rework
  — plus a `uid` computed property nothing outside `ArticleSummary` itself reads (checked directly:
  zero call sites). The server's own integer `article.id` is the natural identity for sync upserts;
  there's no cross-device-identity problem left to solve locally.
- `StoredImage` (SwiftData model), `ImageSync`, `StoredImageRegistrar` — deleted. `ImageStore`
  reworked: `store(remoteURL:isHeader:removeWhiteBackground:)` (download + client-side compress +
  self-computed hash) is replaced by `fetchIfNeeded(hash:) async -> Bool` (network `GET
  /images/:hash` by the server's own hash, write raw bytes verbatim, infer extension from
  `Content-Type`). `FeedLogoView`/`ArticleHeaderLogo`/`ArticleBlockView`'s `yana-img://` resolution
  logic is otherwise unchanged — they already only care about "is this hash on disk yet."
  `FeedLogoResolver`, `ImageCompressor`, `LogoBackgroundRemover` are deleted (server already stores
  final processed bytes for both article images and feed logos).

### `Yana/Aggregators/` disposition (file by file)

The folder itself goes away, but it currently holds a few files that aren't aggregation-specific
and must survive — calling them out explicitly rather than leaving "delete `Aggregators/`" ambiguous:

**Survives, relocated** (e.g. into `Yana/Services/` or `Yana/Reader/` as fits):
- `ArticleSearch.swift` — the title/content/author/feed-name matcher `ArticleListView`'s search
  uses. Nothing to do with aggregation; it happens to live here today. Stays correct as-is because
  content is now eagerly synced (see Local persistence above) — a lazy-fetch design would have
  quietly broken it.
- `Utils/ArticleHeaderLogo.swift`, `Utils/ImageStore.swift` — reworked per the data-model changes
  above, not deleted.
- `Utils/ReaderWeb.swift` — `WKWebView` origin/scheme constants used by the reader's video-embed
  player. Reader plumbing, not aggregation; unrelated to this rework.

**Deleted** (aggregation/scraping-pipeline-specific, all now redundant with server-side work):
`AggregatedArticle.swift`, `AggregationLogic.swift`, `Aggregator.swift`, `AggregatorRegistry.swift`,
`AggregatorType.swift`, `ArticleUpsert.swift`, `FeedConfig.swift`, `FeedLogoResolver.swift`,
`RetentionCleanup.swift`, all of `Concrete/` (16 site scrapers + Reddit/YouTube clients/models),
and from `Utils/`: `BlockParser.swift`, `BlueskyEmbed.swift`, `ContentFormatter.swift`,
`DomainImageOverrides.swift`, `EmbedRewriter.swift`, `FaviconResolver.swift`, `FeedDiscovery.swift`,
`FeedParser.swift`, `FeedURLResolver.swift`, `HTMLUtils.swift`, `HeaderElementExtractor.swift`,
`ImageCompressor.swift`, `LogoBackgroundRemover.swift`.

**`BlockParser.swift` is worth calling out specifically**: it parses raw HTML into `[Block]` during
on-device aggregation. The server's `/articles/:id/content` already returns structured `[Block]`
JSON (the wire format was deliberately designed to match iOS's own `Block`/`InlineRun` model) — the
client only needs to `Decode` it, never parse HTML. This eliminates an entire parsing pipeline, not
just a call site.

**`Utils/HTTPClient.swift` is a partial exception**: most of it (redirect-following scraping
fetches) is dead with the rest of the pipeline, but its `maxImageResponseBytes` (64 MB) cap and
`imageAccept` header — tuned specifically for large Reddit GIFs — are still relevant protections
for the reworked `ImageStore`'s network fetch and should carry over into `Yana/Networking/`, not be
deleted along with the rest of the file.

### Removed wholesale (outside `Aggregators/`)

`AggregationService`, `AggregationWriter`, `AIClient`/`AIProcessor` (for the 6 removed cloud
providers — Apple Intelligence's own on-device implementation is kept), `CredentialTester` paths
for Reddit/YouTube and the removed AI providers, `FeedPortability`, `OPMLCodec`, `LibraryDedup` (no
CloudKit merges left to dedupe), the local retention job, `ImagePrune` and its candidate-quarantine
store.

### AI settings

Settings' AI section collapses to a two-option picker: **Server** (default) and **Apple
Intelligence**. Selecting Apple Intelligence keeps the existing on-device-availability check
(`CredentialTester`'s Apple Intelligence probe survives; everything else in `CredentialTester` for
the removed providers/credentials is deleted). No API keys, no model picker, no per-provider config
UI remain on-device — provider choice/keys for Server mode are configured server-side via the
WebView, now covering all 6 cloud providers (`Mistral`/`Qwen`/`DeepSeek` were added to the server
in the same update that added the prompt endpoint, reaching full parity with iOS's old
bring-your-own-key list minus Apple Intelligence itself).

An `AISummaryProvider` protocol (`produce(from content: String, articleTitle: String) async ->
String?`) has two implementations, selected by the AI mode setting:

- `ServerAISummaryProvider` — calls `POST /api/v1/ai/prompt` with `{ prompt }`, where the prompt is
  built from the same template the existing on-device summarizer uses (for consistent tone/length),
  filled in with the article's plain text/title. Reads back `{ response, provider, model }`.
  Error handling is graceful, not fatal: `429 daily_limit_exceeded`/`monthly_limit_exceeded` and
  `409 no_active_provider` degrade to "no summary available" in the reader (no error dialog) —
  these are expected, recoverable states (rate limit, or the user hasn't configured a provider on
  the server yet), not failures.
- `AppleIntelligenceSummaryProvider` — the existing on-device implementation, re-sourced from
  server-synced content instead of on-device-aggregated content.

Both write the result into the same local-only `summary` field iOS already renders as its own block
between the lead image and the article body — this is never sent back to the server, purely a
local cache of the generated text (regenerated if missing when the article is opened).

### Feed/tag/settings management (WebView)

A new screen presents the server's own web UI (feeds, tags, AI/Reddit/YouTube settings, account/
devices) in a `WKWebView` using the same persistent cookie store the pairing flow authenticated.
Native `FeedsView`, `TagsView`, `FeedEditorView`, `FeedTagsPicker`, and most of
`SettingsScreenView`'s sections (Feeds, Tags, AI provider config, Integrations) are removed; what
remains natively is Reader settings (text size/font/voice/system-browser — genuinely device-local
prefs with no server equivalent), the AI mode picker, the server URL / device-pairing controls, and
About. (Diagnostics is already dead code independent of this rework — see the pre-existing-issues
note at the end of this document — so it's omitted here rather than carried forward.) On Mac, the
same WebView replaces the corresponding `MacSettingsWindow` panes.

### Onboarding (`WelcomeView`)

Three steps, down from three-with-different-content:

1. Welcome / feature highlights (unchanged).
2. Server configuration: enter/edit the server base URL, then run the device-pairing WebView login
   described above.
3. AI mode: Server (default) or Apple Intelligence, with the same on-device availability check
   used in Settings.

No first-feed step — there is no native feed-creation path to onboard into; a first-time user adds
feeds via the WebView after onboarding completes.

### Background refresh & notifications

`BackgroundRefreshManager`'s `BGAppRefreshTask` handler calls `SyncEngine`'s sync directly (no
`/aggregate` trigger — background refresh consumes whatever the server has already produced on its
own schedule) and posts the existing new-article-count notification using the sync result's `new`
count.

## Testing

- `YanaAPIClientTests` — mocked `URLProtocol`, one test per route including error-envelope
  decoding and 404-as-not-found/not-mine (server's enumeration-avoidance convention).
- `SyncEngineTests` — cursor persistence, `new`/`updated`/`removed` application against SwiftData,
  `resyncRequired` handling, `createdAt` preservation on update, pagination looping to head on a
  large first sync, and the partial-failure backfill queue (a content/image fetch failing mid-pass
  doesn't block the cursor and is retried on the next pass) — same spirit as today's
  `ArticleStoreIncrementalTests`.
- `DevicePairingTests` — the state-generation/verification and callback-URL-parsing logic extracted
  as a pure, SwiftUI-free function/struct (the same "extract the state machine so it's testable
  without SwiftUI" pattern `ReaderAnchorController`'s no-ping-pong tests already rely on), covering:
  matching state accepted, mismatched state rejected, malformed callback URL rejected.
- `ImageStoreTests` — fetch-by-hash on miss, no re-fetch when already on disk, extension inferred
  from `Content-Type`.
- UI tests: pairing flow against a local mock server response (or a scriptable stand-in), the
  management WebView loads and carries the session cookie, onboarding's three-step flow.

## Out of scope / follow-ups

- A true per-feed aggregation trigger (today's `/aggregate` runs all enabled feeds) — only worth
  adding if the WebView-hosted feed management still leaves users wanting a native per-feed
  "update now" action.
- AI options key-shape harmonization (server's flat `ai_*` keys vs. iOS's old nested shape) — moot
  for this rework since iOS no longer exposes per-provider config at all; only relevant if a future
  native surface needs to read those keys directly instead of going through `/ai/prompt`.
- `POST /api/v1/ai/prompt`'s daily/monthly usage counter is shared with the server's own
  per-feed `applyAiOptions()` pipeline — worth keeping in mind that heavy on-demand summarizing
  from the app can exhaust the same quota the user set for automatic per-feed AI processing.
- App Store screenshot fixtures (`fastlane screenshots`, `ScreenshotSeed`) need a content update,
  not an architecture change: they seed `Feed`/`Article` rows directly into local SwiftData, which
  still works unchanged as a fixture mechanism regardless of how real data normally arrives. But
  the `05_AI` shot is explicitly captioned as "the AI bring-your-own-key section in Settings" —
  that section no longer exists post-rework, so its caption/content needs to change to whatever the
  new two-mode AI section looks like. Tracked here so it isn't forgotten, not solved in this spec.
- Two pre-existing issues found while auditing for this rework, unrelated to it but worth knowing
  about: the Mac Catalyst target currently fails to compile (`MacSettingsWindow.swift` references
  the deleted `SyncLogView`), and the five-tap diagnostics-reveal gesture on iOS is now dead code
  (its only consumer was removed in the same CloudKit-removal commit that broke the Mac build).
  Flagged as a separate background task rather than folded in here.
