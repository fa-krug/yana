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
| Local persistence | Kept. SwiftData remains a local mirror, now populated by a sync engine reading `/api/v1/articles/sync` instead of by on-device aggregation. Preserves `ArticleStore`, the endless timeline, and the reader's lazy block-loading largely as-is. |
| Starred | Becomes a plain `Article.starred: Bool`, synced via `PATCH /articles/:id`, replacing the built-in "Starred" tag / `StarredRegistry`. UI (a Starred filter chip) is unchanged in appearance. |
| Tag filtering | Becomes live (joined from `Feed.tagIds` at display time each sync) instead of snapshotted onto each article at import. Accepted behavior change — matches the server's live many-to-many model. |
| `read` field | Present on the wire, intentionally unused. Preserves the existing "no read/unread state" product decision; the field is decoded but never acted on or written. |
| Images and feed logos | Both fetched by content hash via `GET /api/v1/images/:hash` into a reworked `ImageStore` disk cache. The CloudKit-era `StoredImage`/`ImageSync`/`StoredImageRegistrar` bridge (already dead weight since CloudKit's removal) is deleted outright, not adapted. Client-side recompression/background-removal (`ImageCompressor`, `LogoBackgroundRemover`) is deleted — the server already stores final, processed bytes. |
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
- `SyncEngine` — replaces `AggregationService`'s write path. Holds the opaque sync cursor
  (persisted device-locally, not synced — it's per-device network state, same tier as
  `UpdateInterval`), calls `/articles/sync`, and:
  - Upserts `new`/`updated` article summaries into SwiftData (`createdAt` preserved on update,
    matching today's "re-fetched articles keep their original `createdAt`" rule).
  - Hard-deletes rows named in `removed`.
  - On `{ resyncRequired: true }`, drops the stored cursor and re-pulls from scratch (equivalent to
    today's full re-read fallback in `SummaryIndexMerge`).
  - Article bodies stay lazy: `ArticleBlockView`'s page resolves `[Block]` content on render via
    `GET /articles/:id/content`, mirroring the current lazy-resolve-by-`persistentID` pattern —
    just fetched over the network instead of read from a local `blockData` column that's already
    fully populated. (Blocks are still cached locally in SwiftData once fetched, so re-opening an
    article already read doesn't re-fetch.)

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
- `StoredImage` (SwiftData model), `ImageSync`, `StoredImageRegistrar` — deleted. `ImageStore`
  reworked: `store(remoteURL:isHeader:removeWhiteBackground:)` (download + client-side compress +
  self-computed hash) is replaced by `fetchIfNeeded(hash:) async -> Bool` (network `GET
  /images/:hash` by the server's own hash, write raw bytes verbatim, infer extension from
  `Content-Type`). `FeedLogoView`/`ArticleHeaderLogo`/`ArticleBlockView`'s `yana-img://` resolution
  logic is otherwise unchanged — they already only care about "is this hash on disk yet."
  `FeedLogoResolver`, `ImageCompressor`, `LogoBackgroundRemover` are deleted (server already stores
  final processed bytes for both article images and feed logos).

### Removed wholesale

`Yana/Aggregators/` (all site-specific scrapers, `AggregatorRegistry`, `Aggregator` protocol,
`AggregatedArticle` DTO), `AggregationService`, `AggregationWriter`, `AIClient`/`AIProcessor` (for
the 6 removed cloud providers — Apple Intelligence's own on-device implementation is kept),
`CredentialTester` paths for Reddit/YouTube and the removed AI providers, `FeedPortability`,
`OPMLCodec`, `LibraryDedup` (no CloudKit merges left to dedupe), the local retention job, `ImagePrune`
and its candidate-quarantine store.

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
About/Diagnostics. On Mac, the same WebView replaces the corresponding `MacSettingsWindow` panes.

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
  `resyncRequired` handling, `createdAt` preservation on update — same spirit as today's
  `ArticleStoreIncrementalTests`.
- `DevicePairingTests` — the state-generation/verification and callback-URL-parsing logic extracted
  as a pure, SwiftUI-free function/struct (mirroring how `DiagnosticsReveal` is tested), covering:
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
