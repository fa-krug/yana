# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Yana iOS is a **native SwiftUI iOS/Mac Catalyst app** that is a **thin, offline-first client**
for a self-hosted **Yana Server** (`yana-server`, a separate project). The server does all the
work — fetching/parsing feeds, running scrapers, calling AI providers — and this app pairs with a
server the user runs themselves, syncs the resulting articles/feeds/images down into a local
SwiftData mirror for instant offline browsing, and pushes user actions (star, reload, trigger an
aggregation run) back up as API calls. There is **no on-device aggregation** and **no
per-provider credentials stored on the phone** any more: feed/tag/AI-provider configuration
happens in the server's own web UI, reached from Settings through an embedded WebView that
bootstraps a fresh, short-lived, single-use server session token on every appearance. Yana is
open source under the MIT license (`LICENSE`); the
source and issue board live at
[github.com/fa-krug/yana](https://github.com/fa-krug/yana).

## Commands

### Development
- `xcodegen generate` — generate the Xcode project from `project.yml`
- `open Yana.xcodeproj` — open the project in Xcode
- Build and run via Xcode: select **Yana** scheme

### Building from command line
- `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build` — build iOS target
- `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test` — run tests

### Prerequisites
- `brew install xcodegen` — install XcodeGen (required to generate `.xcodeproj`)

### App Store screenshots
- `fastlane screenshots` — capture + frame the App Store screenshots (**en-US + de-DE**, **iPhone-only**,
  6.9″ `iPhone 17 Pro Max`, 1320×2868). Requires `brew install fastlane`. The lane captures each locale
  in its own `capture_screenshots` pass with `erase_simulator`/`reinstall_app` so every locale is
  deterministic — the 9:41 status-bar override re-applies and the reader re-parks on the hero article
  (a single multi-language pass loses the override on the second locale and leaks reader position).
- The set is a 5-shot story flow (numeric key = App Store order): `01_Reader` (hero, native reader with
  the AI summary block) → `02_Timeline` → `03_Feeds` (multi-source proof) → `04_Search` → `05_AI` (the
  Settings AI section). Keep these keys in sync across `ScreenshotUITests.swift`, `Framefile.json`'s
  implied filter, and the `{en-US,de-DE}` caption files.
  `ScreenshotUITests.swift`'s identifier lookups match the server-API client rework
  (`"settings.manage"` for the manage row, `"settings.aiSection"` set by `AIModeSettingsSection`)
  and the capture test passes; the `05_AI` caption strings (`title.strings`/`keyword.strings` in
  both locales) describe the current two-mode AI story (Apple Intelligence or your server's
  configured provider), not the deleted "bring your own key" flow.
- Content is a DEBUG-only offline fixture (`ScreenshotSeed`, `Yana/Utilities/ScreenshotSeed.swift`)
  triggered by the `-UITEST_SCREENSHOTS` launch argument that the `ScreenshotUITests` capture flow
  passes — no network, no committed binaries, fully reproducible. `ScreenshotSeed` authors a small
  library of **fully original** invented feeds/articles in-code and generates all imagery in-process:
  `ScreenshotImageFactory` (article lead images) and `ScreenshotLogoFactory` (per-feed logo tiles),
  stored content-addressed via `ImageStore.storeData` so the `yana-img://` refs resolve — the same
  local disk cache the real sync path fetches into by content hash, just pre-seeded here instead of
  fetched. Nothing is fetched from or copied out of real feeds, so there is no third-party
  licensing/trademark exposure.
- To change what appears: edit `ScreenshotSeed.feedSpecs` (feed names, tags, article titles/summaries/
  bodies) and/or the two generators, then re-run `fastlane screenshots`. If you change titles, check the
  `04_Search` query ("battery") in `YanaUITests/ScreenshotUITests.swift` still matches an article.
- Framing: `fastlane/screenshots/Framefile.json` frames on a `background.png` sized to exactly
  1320×2868 (so framed output stays App-Store-valid) — a subtle indigo→violet gradient behind two-tone
  captions: a lavender `keyword` (`keyword.strings`, `#C9B8FF`) + a white `title` (`title.strings`),
  both rendered in the bundled `OpenSans-Bold.ttf` (SIL OFL — frameit resolves the font relative to the
  screenshots dir, so a system font can't be used). Captions are localized per locale: `en-US/` and
  `de-DE/` each hold `keyword.strings` + `title.strings` (German is Apple-style, infinitive). frameit
  reads captions from the folder where the captures land, so each locale's strings must sit in the
  full-tag folder that matches its `languages(...)` entry (`de-DE`, not `de`).
- Output: `fastlane/screenshots/en-US/` and `fastlane/screenshots/de-DE/` — both the raw captures
  (`*.png`) and the framed `*_framed.png` are committed to the repo (only fastlane run artifacts —
  `screenshots.html`, `test_output/`, `report.xml`, `README.md` — stay gitignored).
- Gotchas: the `screenshots` lane bakes `LANG/LC_ALL=en_US.UTF-8` into the Fastfile because fastlane
  crashes on a bare `C`/US-ASCII shell locale. That bake uses `ENV["LANG"] ||= …`, which does **not**
  override an already-set-but-empty `LANG` (an empty string is truthy in Ruby), so if the lane dies with
  a `FastlanePtyError` / `"Cr" on UTF-16` encoding crash, export `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`
  explicitly before `fastlane screenshots`. `ScreenshotSeed` is idempotent (bails if any `Feed`
  exists); the lane now runs `erase_simulator: true` per locale pass, so a stale library from a prior
  run no longer persists — a manual `xcrun simctl shutdown all; xcrun simctl erase all` is only needed
  if you capture outside the lane.

### macOS App Store screenshots
- `fastlane mac screenshots_mac` — capture the Mac App Store screenshots (**en-US + de-DE**,
  **2880×1800**, the largest allowed Mac size). Output: `fastlane/screenshots_mac/{en-US,de-DE}/`,
  committed like the iPhone set.
- **This shares nothing with the iPhone lane, by necessity:** `capture_screenshots` (fastlane
  snapshot) drives iOS Simulator destinations only and cannot target Mac Catalyst, and
  `frame_screenshots` (frameit) has no Mac device frames. So the Mac path is its own test
  (`YanaUITests/MacScreenshotUITests.swift`), its own lane, and its own output directory — kept
  **outside** `fastlane/screenshots/` so the iOS lane's `frame_screenshots` never sees it.
- 4-shot set (numeric key = App Store order): `01_Reader` (main window — sidebar + hero article)
  → `02_Search` (sidebar search for "battery") → `03_Feeds` (Settings › Manage) → `04_AI`
  (Settings › AI). Keep these keys in sync between `MacScreenshotUITests.swift` and `MAC_SHOTS`
  in the Fastfile. The test now selects the Settings sidebar pane by its current raw value
  (`mac.settings.pane.manage`), matching `SettingsPane`'s (`Yana/Reader/Mac/WindowID.swift`) actual
  pane set — `general, reader, manage, ai, about`, with no `.feeds` case any more.
- Shots are **plain captures — no device frame, no gradient, no captions** (the Mac App Store
  convention). Localization comes from the app chrome itself, forced via `-AppleLanguages` /
  `-AppleLocale` launch arguments.
- How it works: the test attaches each window capture as an `XCTAttachment`
  (`lifetime = .keepAlways`) — the only sandbox-safe route out, since the Catalyst test runner
  cannot write outside its container. The lane then runs `xcresulttool export attachments`,
  resolves names through the emitted `manifest.json`, and composites the two Settings shots over
  the `01_Reader` capture with `fastlane/mac_composite.swift` (CoreGraphics; `sips` cannot
  composite and ImageMagick would be a new dependency).
- Content is the same DEBUG-only offline fixture as the iPhone set (`ScreenshotSeed`, via
  `-UITEST_SCREENSHOTS`). Per-locale isolation replaces `erase_simulator`: there is no simulator
  to erase, so the test passes `-UITEST_RESET_LIBRARY` alongside it and relies on `YanaApp`
  running the reset before the seed.
- `-UITEST_MAC_SCREENSHOTS` (`Yana/Utilities/MacScreenshotWindow.swift`) pins the main window to
  1440×900pt — 2880×1800 at 2x — and suppresses the Mac launch refresh (whose spinner and error
  toast would otherwise land in a frame) and the pre-server-migration notice window (see
  **Architecture**), both of which would otherwise pop up mid-capture.
- The capture run uses a **throwaway SwiftData store** in the system temp directory
  (`yana-screenshots.store` + its `-wal`/`-shm` siblings, deleted before each run). The developer's
  real Mac library under `~/Library/Application Support/` is never touched.
- Gotchas: exact sizing **requires a Retina (2x) display** — the lane fails loudly if the direct
  shots are not exactly 2880×1800, and the compositor fails loudly if the base image has the wrong
  aspect ratio. Neither falls back silently. Both `YanaTests` and `YanaUITests` must keep
  `SUPPORTS_MACCATALYST`, because `xcodebuild` builds every test target in the scheme even with
  `-only-testing`. Per-locale isolation works via `-UITEST_RESET_LIBRARY` (not `erase_simulator`,
  which has no Mac equivalent); UserDefaults and Keychain carry over between runs, which is why the
  test pins settings via a UserDefaults argument domain rather than relying on persisted state.
  The Mac surfaces carry `mac.*` accessibility identifiers purely so the test can navigate
  locale-independently; the sidebar search field is matched as `app.searchFields` because
  `.searchable` does not forward an identifier reliably.
- **Codesigning gotchas (Mac Catalyst only — the iPhone lane ad-hoc signs and is immune):**
  - `codesign … errSecInternalComponent` means `codesign` cannot read the signing key. Two distinct
    causes: (a) the login keychain's signing keys lack `codesign:` in their partition list — fix with
    `security unlock-keychain ~/Library/Keychains/login.keychain-db` then
    `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<password>' ~/Library/Keychains/login.keychain-db`;
    (b) the shell is not in the **Aqua** launchd session (check `launchctl managername`) — a
    `Background` session is never served a signing key, so the lane must be run from a real
    Terminal, not from an automation/agent shell.
  - `invalid or unsupported format for signature … <Framework>.cstemp` means a PREVIOUS codesign run
    died partway and left `.cstemp` turds inside the copied XCTest frameworks. Clear them with
    `rm -rf <DerivedData>/Build/Products/Debug-maccatalyst` and re-run; deleting only the `.cstemp`
    files is not enough, because the frameworks themselves are left half-signed.

### Website (GitHub Pages)
- The project ships a self-contained marketing + legal site under `docs/site/`, deployed to GitHub
  Pages at **`yana.fa-krug.de`** by `.github/workflows/pages.yml` on every push to `main` (one-time
  manual setup: repo **Settings → Pages → Source: GitHub Actions**). Design spec:
  `docs/superpowers/specs/2026-07-06-github-pages-site-design.md`.
- Plain HTML/CSS/JS, **no build step** (served as-is) and **no external requests** (system font stack,
  no CDN/trackers — mirrors the app's privacy posture). Pages: `index.html` (landing) plus
  `privacy.html`, `impressum.html`, `terms.html`, `server.html`. Copy is reused from the README and
  `docs/app-store/description-{en,de}.md`.
- **Bilingual** EN/DE from one set of pages: every translatable element carries a `lang-en`/`lang-de`
  class, `<html data-lang>` drives visibility via CSS, and `assets/app.js` runs the header toggle
  (persisted to `localStorage`; default EN). When adding copy, always add both language spans.
- Images live in `docs/site/assets/img/` and are committed (Pages serves them directly).
  `assets/img/README.md` maps each file to where it is used.
  The screenshots (`hero.png`, `screen-timeline.png`, `screen-search.png`, `screen-feeds.png`) are
  the raw (unframed) `fastlane screenshots` captures from
  `fastlane/screenshots/en-US/` (`01_Reader`/`02_Timeline`/`04_Search`/`03_Feeds` respectively),
  downscaled to ~640px wide with `sips`; the site rounds their corners in CSS, so use the raw captures, **not** the
  device-framed App-Store `*_framed.png`. To refresh: re-run `fastlane screenshots`, downscale, and
  overwrite the files under `assets/img/`.

## Architecture

### SwiftUI + SwiftData + thin sync client

- **Models** (`Yana/Models/`): SwiftData `@Model` classes — `Feed`, `Tag`, `Article` — plus
  `AppSettings` (the preferences store, including the `AIMode` enum), `UpdateInterval` (per-device
  background-refresh schedule), and `ServerMigrationEligibility` (pure state machine for the
  one-time "Yana now requires a server" notice shown to devices that finished onboarding before this
  rework shipped). **These models store only what this client actually renders.** A `Feed` is a
  name, the server's id (as `identifier`), a `logoImageHash` and `tagIDs`; the wire's `aggregator`,
  `enabled`, `dailyLimit` and `updatedAt` are feed *configuration*, owned by the server and edited
  in its web UI, so `SyncFeedWire` does not even decode them. `Feed.tagIDs: [Int]` is a **live**
  join to the server's tag ids, refreshed on every `/feeds` fetch (unlike the old per-article tag
  snapshot this replaced, tag membership always reflects the feed's current server-side state — see
  **Key patterns**); there is deliberately **no** `Article.tags` relationship and no `Tag.articles`
  inverse, because the join is the only tag mechanism.
  `Article.starred: Bool` is a plain field (no more built-in "Starred" tag or `Tag.isBuiltIn`).
  `Article.serverID: Int?` is the sync identity `SyncWriter` upserts/removes/backfills by.
  `Article.hasContent: Bool` tracks whether `/articles/:id/content` has landed yet for this row,
  driving the sync engine's backfill retry. `Article.read: Bool` is read state: display-only, and it
  deliberately takes no part in the timeline's order (see **Key patterns**). Assign it directly —
  the old `readRank: Int` sort mirror and its `setRead(_:)` setter are gone, along with the index
  every sync insert used to maintain for it. `Article.blocks` (computed from `blockData`) is
  unchanged from before — see **Reader**.
  **When adding a column here, check something reads it.** A batch of write-only columns
  (`Article.iconURL`/`syncFeedIdentifier`/`syncAggregatorType`, `Tag.sortOrder`/`createdAt`, the
  four `Feed` config fields above) accumulated by being mirrored from the wire and never rendered.
- **Networking** (`Yana/Networking/`): `YanaAPIClient` (a thin typed wrapper over every
  `/api/v1/**` route — `get`/`patch`/`post`/`getRaw`, Bearer-token auth, ISO-8601 date decoding,
  decodes the server's `{ error: { code, message } }` envelope into `YanaAPIError` on failure) and
  `BlockWireDecoding` (`WireDocument`/`WireBlockBox`/`WireInlineRun`: a custom `Decodable` translation
  layer that turns the server's `type`-discriminated block JSON — matching
  `yana-server/src/lib/aggregators/blocks/schema.ts` — into the app's existing `Block`/`InlineRun`
  enum. `Block` itself keeps its compiler-synthesized `Codable`, which encodes differently, so this
  is a separate decode path, not a `Block` extension). Four more files back the real server-
  completion polling `UpdateAndSync` does (see **Sync**/**Actions** below): `RunStatus.swift`
  (`RunStatusResponse`, the `GET /api/v1/runs/:id` wire shape, `status` a plain `String` — not a
  closed enum — so a future server-added status degrades gracefully instead of failing to decode);
  `JobEvent.swift` (`JobEventPayload`/`RunEventPayload`/`ReadingPositionEventPayload`, mirroring
  `yana-server`'s `ApiEvent` "job"/"run"/"readingPosition" SSE variants, same plain-`String`-status
  reasoning for the first two); `SSEFrameAccumulator.swift` (pure,
  synchronous SSE frame parsing — one line in, an `SSEFrame` out on a blank-line terminator, per the
  SSE spec, with `: ping` comment lines ignored); and `JobEventsClient.swift` (streams
  `GET /api/v1/jobs/events`, `yana-server`'s per-user SSE feed of job/run/reading-position
  completion — the only way to observe a standalone `article.reload` job finishing, since that job
  has `runId: null` and is invisible to `/runs/:id`; documented server-side as best-effort, so
  callers must have their own fallback for a dropped connection or a missed event —
  `UpdateAndSync.pollForReloadedContent` falls back to a direct re-fetch,
  `ReadingPositionLiveSync` falls back to the next full sync's periodic pull).
- **Auth / device pairing** (`Yana/Services/DevicePairing.swift`, `Yana/Views/DevicePairingView.swift`,
  `Yana/Services/KeychainService.swift`, `Yana/Services/AuthenticatedClient.swift`): `DevicePairing`
  is a pure state machine — `makeSession` mints a client-generated, never-persisted random `state`
  (the same anti-forgery pattern `gh auth login --web` uses), `pairingURL` builds the server's
  `/login?next=/device/pair&state=...&scheme=yana&deviceName=...` URL, and `handleCallback` validates
  a `yana://auth-callback?token=...&state=...` redirect against the session's `state`.
  `DevicePairingView` drives this via `ASWebAuthenticationSession` — a system-managed, Safari-context
  browser sheet — rather than an in-app `WKWebView`. This is required for iCloud Keychain passkey
  sign-in to work at all: `WKWebView` only surfaces platform-authenticator passkeys for a domain the
  app has declared in its `webcredentials:` Associated Domains entitlement, which is impossible here
  since the server address is arbitrary and self-hosted (unknown at build time, different per user).
  `ASWebAuthenticationSession` has no such restriction. `yana://` is registered as a
  `CFBundleURLTypes` scheme in `Info-iOS.plist` (not required by `ASWebAuthenticationSession` itself,
  which intercepts the callback scheme directly, but kept since it documents the scheme in use). This
  session's cookies land in Safari's shared cookie jar (`HTTPCookieStorage.shared`), not the
  `WKWebsiteDataStore` `ManagementWebView` reads from — the two are entirely separate on iOS with no
  automatic sharing, and on Mac Catalyst App Sandbox isolates the app's `HTTPCookieStorage.shared`
  from the system's out-of-process Safari auth agent `ASWebAuthenticationSession` runs through there,
  so a one-shot cookie copy at pairing time never reliably reached `ManagementWebView`'s cookie store
  at all on that platform. `ManagementWebView` no longer depends on this session's cookies: instead,
  every time it appears it calls `POST /api/v1/auth/webview-session-token` for a fresh,
  Bearer-authenticated, short-lived, single-use token and loads
  `GET /webview-session?token=...&next=...`, which the server exchanges for a real session cookie —
  see `Yana/Views/ManagementWebView.swift`'s module doc. On success the
  token is stored via `KeychainService.saveDeviceToken` — the Keychain service is now just
  `saveDeviceToken`/`loadDeviceToken`/`deleteDeviceToken` over one key, written with
  `kSecAttrSynchronizable: false` (device-local; no more per-provider API keys, no more iCloud
  Keychain sync). `loadDeviceToken` keeps a one-slot, lock-protected in-memory cache
  (`OSAllocatedUnfairLock<String??>`) rather than hitting `SecItemCopyMatching` on every call — the
  Keychain round-trip was showing up per-row in `SyncEngine.backfillMissingContent`'s bounded task
  group, which calls `AuthenticatedClient.current()` (and thus this) once per article. The triple-
  optional distinguishes "never read" (`.none`) from "read and confirmed absent" (`.some(nil)`) so a
  genuinely-unpaired device doesn't keep re-querying Keychain either; `saveDeviceToken`/
  `deleteDeviceToken` update the cache in lockstep. `AuthenticatedClient.current()` resolves the
  app's current `YanaAPIClient?` from `AppSettings.serverBaseURL` + the stored token; `nil` means
  "not paired yet" and every call site (the launch-time sync, `BackgroundRefreshManager`, the
  reader's action handlers) treats that as "nothing to do," not an error. `DevicePairing.classify`
  (`Yana/Services/DevicePairing.swift`) turns an `ASWebAuthenticationSession` completion into a
  `PairingOutcome` distinguishing four previously-collapsed-into-one-silent-"cancelled" failure
  modes — user cancel, session/transport failure, anti-forgery state mismatch, and a malformed
  callback (`PairingFailure`) — so `DevicePairingView` can show a failure reason instead of quietly
  doing nothing (audit U1). Separately, `SyncEngine.sync()` posts `.yanaSessionInvalidated`
  whenever it detects the stored token has been revoked/expired (a `YanaAPIClientError.unauthorized`
  from either the top-level sync or the content backfill loop) and deletes it; `ContentView` observes
  that notification and re-runs its re-pairing gate immediately rather than waiting for the next
  app-foreground/launch check, so a session revoked from another device prompts re-pairing right
  away (audit U2).
- **Sync** (`Yana/Services/SyncEngine.swift`, `Yana/Services/SyncWriter.swift`): the orchestrator +
  write-path pair that replaced `AggregationService`/`AggregationWriter` and the entire
  `Yana/Aggregators/` tree (deleted wholesale — no more `AggregatorType`, `AggregatorOptions`,
  per-source scraper types, or `AggregatorRegistry`). `Yana/Services/ArticleSearch.swift` is now
  only `searchSummaries` over `ArticleListSearch`'s `#Predicate`-backed fetch (see **Views** below);
  the in-memory `matches`/`filter` matcher it used to also carry, and the `StringMatch`/`NameSearch`
  helpers behind it, were orphaned by that move and are deleted.
  `SyncEngine.sync()` (`@MainActor`)
  first flushes any pending writes in `PendingWriteQueue`, then replaces the local `Feed` mirror
  wholesale from `GET /api/v1/feeds` (small, unpaginated — no incremental-delta protocol needed
  there), then paginates `GET /api/v1/articles/sync` via an opaque cursor (`AppSettings.syncCursor`,
  `nil` forcing a full resync), applying each page's `new`/`updated` summaries and `removed` server
  ids through `SyncWriter`. A `resyncRequired: true` response (the server no longer recognizes the
  cursor) clears it and loops again from scratch rather than giving up. This is an **offline-first,
  not lazy-on-render** design: a full pass also eagerly backfills full block content for every
  locally-known article that doesn't have it yet (`backfillMissingContent`, driven by
  `Article.hasContent == false`, not by re-listing from `/articles/sync`) via `GET /articles/:id/content`,
  at bounded concurrency (`runBounded`, a sliding-window `withTaskGroup` capped at
  `maxConcurrentContentFetches` = 6) so full-text search and true offline reading both work without
  a network round-trip per article. Individual content-fetch failures are swallowed, not fatal — they
  just retry on the next sync pass. Every image an article's body actually references (`.image`
  refs and embed `thumbnailRef`s — `Block.imageHashes(in:)`, recursing into lists/blockquotes) is
  fetched into `ImageStore` right alongside that article's content, and every feed's logo is
  fetched the same way from `syncFeeds()`; this is what makes the reader's `LeadImageReveal` gate
  (`ArticleBlockView.swift`) almost never have to wait on its own bounded on-demand fallback. A
  final `pruneOrphanedImages` pass diffs `ImageStore.allHashes()` against
  `SyncWriter.referencedImageHashes()` (every surviving article's block-image hashes ∪ every feed's
  logo hash) and deletes whatever's left — so an image whose last referencing article is gone
  (`applyRemovals`'s explicit list, a feed's cascade-delete in `replaceFeeds`, or a local
  swipe-to-delete since the last sync) doesn't linger on disk forever; this is pure local disk I/O,
  so it runs even when the rest of the pass was offline/degraded. This pass is gated, not
  unconditional: decoding every local article body to compute `referencedImageHashes` isn't free, so
  `performSync` only runs it when the pass could plausibly have orphaned something — a server-side
  removal actually deleted a row, a feed disappeared, or `AppSettings.imagePruneNeeded` was set by a
  local swipe-to-delete (`ArticleListView`) or a Mac sidebar delete (`TimelineModel`) since the last
  sync; the flag is cleared right after the prune runs. `SyncWriter` (`@ModelActor`) does the actual `ModelContext`
  writes: `upsertSummaries` matches by `Article.serverID`, and never re-stamps `Article.date` (the
  original article date, what the timeline shows and sorts by) or `createdAt` on update — an
  article's timeline position never jumps on re-fetch, matching the server's own treatment of a
  publication date as immutable (the random import-jitter that used to scatter a batch's
  `createdAt`s under the old client-side-aggregation design is gone; imports are no longer a
  client-side batch operation), and applies `read` with an upgrade-only rule on update
  (unconditional on insert); `applyContent` decodes a `WireDocument` into `[Block]` and sets
  `hasContent = true`, tolerating a race where the matching article hasn't landed locally yet;
  `applyRemovals` deletes by `serverID` one id at a time (a single `IN`-with-`??`-coalesce predicate
  compiles but crashes at fetch time — CoreData's SQL generator can't use a `TERNARY` as an `IN`
  LHS); `replaceFeeds` upserts by the server's feed id (stored as `Feed.identifier`, string form —
  feeds have no other natural client-side identity any more).
- **Actions** (`Yana/Services/ArticleActions.swift`, `Yana/Services/UpdateAndSync.swift`): the
  user-initiated write/trigger surface, separate from `SyncEngine`'s read path. `ArticleActions`
  is a thin façade — `setStarred` (`PATCH /articles/:id`), `reload` (`POST /articles/:id/reload`),
  `updateAll` (`POST /aggregate`) — that only sends a request and decodes its ack; it never touches
  the local SwiftData mirror. `reload`/`updateAll`'s ack is just a job/run id, not new content (the
  server does the re-fetch asynchronously), so `UpdateAndSync` follows up with real completion
  detection instead of a blind fixed backoff: `pollForFreshContent` polls `GET /api/v1/runs/:id`
  (`RunStatusResponse`) until the run's status is no longer `"running"` — tolerating transient
  `.transport` failures for a few consecutive attempts rather than aborting on the first network
  blip, but bailing immediately on `.unauthorized`/`.decoding`/`.server(...)` since those mean the
  run genuinely can't be queried — then runs `SyncEngine.sync()` exactly once, used by the reader's
  pull-down / "Update All" flow. `pollForReloadedContent` instead waits on `JobEventsClient`'s SSE
  stream (`GET /api/v1/jobs/events`) for a terminal `job` event matching the reload's `jobId` (that
  job has `runId: null`, so `/runs/:id` can never see it), and only on a `"failed"`/`"cancelled"`
  event returns without a network call; a `"completed"` event, or no matching event arriving within
  `eventTimeout` (a dropped SSE connection is documented server-side as best-effort — the default
  timeout is a short 10s specifically to bound this worst case, since the fallback below is cheap),
  falls back to exactly one direct re-fetch of that article's content (bypassing `SyncEngine`'s
  `hasContent`-gated backfill, which — once triggered prematurely mid-poll — would permanently block
  any later retry, since nothing else ever resets `hasContent` back to `false`). Starring
  and marking read are both optimistic, funneled through the shared `ArticleWrites` facade — flip the
  local flag and save immediately, then fire the PATCH; on failure the change is enqueued into
  `PendingWriteQueue` (backed by `AppSettings.pendingWrites`) instead of being rolled back, and
  `SyncEngine.sync()` retries every queued write opportunistically before its normal pull. Both stay
  silently local-only when not paired. `ArticleWrites.markRead` is now a thin wrapper over the more
  general `ArticleWrites.setRead(_:read:...)`, which also backs the reader/list's manual Mark as
  Read/Unread controls (there was previously no supported way to mark an already-read article back
  to unread); both no-op when the article already matches the target `read` value, so re-displaying
  an already-read page (e.g. swiping back over it) never fires a redundant PATCH.
- **Images** (`Yana/Services/ImageStore.swift`, `Yana/Views/Config/FeedLogoView.swift`,
  `Yana/Services/ArticleHeaderLogo.swift`): `ImageStore` is a disk cache keyed by content hash,
  fetching `GET /api/v1/images/:hash` on cache miss and writing the raw bytes verbatim under that
  hash — no recompression, no re-hashing, no remote-URL resolution, no background removal, no HTML
  rewriting client-side any more (the server already delivers final processed bytes; the hash is the
  server's own identity). The 64MB response cap (`maxImageResponseBytes`) is carried over from the
  old on-device-scraping HTTP client as a client-side protection the server doesn't itself enforce.
  Article/feed-logo references use `yana-img://<hash>` (the server delivers the ref directly in
  `WireBlock.image`/`Feed.logoImageHash`). The CloudKit-era `StoredImage` model and `ImageSync` bridge
  are both gone — there is nothing to register or mirror any more, just fetch-on-miss.
- **AI** (`Yana/Services/AISummaryProvider.swift`, `Yana/Services/AppleIntelligenceChunkedSummarizer.swift`,
  `Yana/Services/AppleIntelligenceClient.swift`, `AppSettings.aiMode`): exactly **two** modes now —
  `AIMode.server` and `.appleIntelligence` — replacing the deleted 6-provider network AI stack
  (`AIClient`, `AIProcessor`, `AIReadiness`, per-provider Keychain keys, `CredentialTester`'s
  Reddit/YouTube/AI-verification functions, and the `CredentialTestControls`/`CredentialTest`
  Settings-UI helper it drove — including the `CredentialTestError` enum, which outlived that
  deletion for a while with no caller left and is now gone too). `ServerAISummaryProvider` calls
  `POST /api/v1/ai/prompt` with a fixed summarize prompt against whatever provider the server is
  configured with; any failure (rate limit, no provider configured, provider error) degrades to
  `nil` — "no summary available" is an expected, silent outcome, never a user-facing error.
  `AppleIntelligenceSummaryProvider` runs entirely on-device via `AppleIntelligenceChunkedSummarizer`
  (extracted from the former `AppleIntelligenceProcessor`, keeping only the summarize path — the
  improve-writing/translate paths and their `AIOptions`/`AggregatedArticle` plumbing are gone): the
  same chunk → per-chunk-summary → reduce map-reduce over the ~4096-token on-device context window,
  now with hardcoded generation knobs (temperature 0.3, 2000 max tokens) since the settings that used
  to feed them were deleted along with the network stack. **This path is plain text end to end.**
  `ReaderActions` has always passed `Article.plainText`, but the summarizer used to call itself
  `summarize(html:)` and run that text through a SwiftSoup chrome-stripper and an HTML-element
  chunker. Both were left over from when bodies were HTML, and the chunker's HTML split found no
  elements in plain text, so it took its fallback and returned the whole article as ONE chunk —
  the map-reduce never ran and long articles overflowed the context window. `ArticleChunker` now
  splits on the blank lines `BlockParser.plainText` actually emits
  (`ArticleChunkerTests.plainTextArticleIsActuallyChunked` pins this). `AISummaryReadiness.isReady(mode:)` gates
  whether the reader's "Summarize" action is offered at all — `.server` is always ready (it degrades
  gracefully on its own), `.appleIntelligence` needs `AppleIntelligenceClient().availability == .available`
  since showing the button with no usable model is worse than hiding it.
- **ArticleStore** (`Yana/Services/ArticleStore.swift`): **unchanged in design** from before this
  rework — `@MainActor @Observable`, loads the whole library's lightweight `ArticleSummary` metadata
  once via an `@ModelActor` loader wrapped in `OffMainActor.run`, then keeps it current
  **incrementally** via `ModelContext.didSave` (`LibraryChangeSet` + `SummaryIndexMerge` splice rows
  proportional to the change, falling back to a full re-read above `spliceLimit`), with a disk cache
  written on a delay and flushed on scene-background. The one thing that *did* change: `didSave`
  fires for every local write now (`SyncWriter`, starring, image fetches) because that's the only
  write path there is — the second observer this class used to run on
  `.NSPersistentStoreRemoteChange` (to catch CloudKit merges, which land below SwiftData with no
  `didSave` posted) is gone, since `AppContainer.shared` no longer configures a `cloudKitDatabase` at
  all (CloudKit/iCloud sync was removed from this app before this rework began).
- **Timeline anchor / reading-position sync** (`Yana/Services/TimelineAnchorWriter.swift`,
  `Yana/Services/ReadingPositionSync.swift`, `Yana/Services/ReadingPositionLiveSync.swift`,
  `Yana/Reader/ReaderAnchorController.swift`, `Yana/Reader/Mac/TimelineModel.swift`): server-backed,
  not the old CloudKit-era cross-device-sync design this file used to document, and not purely
  device-local either. `TimelineAnchorWriter.record`
  does two things on every user-driven selection change (a completed swipe, a sidebar click,
  Next/Previous Article, or picking an article from the list): it persists the current article's
  `identifier` to `AppSettings.timelineAnchorIdentifier` (device-local `UserDefaults`, always
  immediate — offline-first, navigating never waits on network) alongside its `serverID` to the
  parallel `AppSettings.timelineAnchorServerID` field, and it schedules a debounced push
  of that article's `serverID` to `PATCH /api/v1/reading-position` via `ReadingPositionSync` (a
  ~2s idle debounce, so rapid timeline navigation doesn't fire a PATCH per page). A failed push is
  queued in `AppSettings.pendingReadingPositionPush` — a single field, not folded into
  `PendingWriteQueue`, since a reading position has no per-article multiplicity — and retried by
  `ReadingPositionSync.flushPending`, called from `SyncEngine.performSync()` right alongside
  `PendingWriteQueue.flush`, before any pull. `SyncEngine.syncReadingPosition()` pulls
  `GET /api/v1/reading-position` on every sync, gated by `updatedAt` last-writer-wins against
  `AppSettings.readingPositionUpdatedAt` (so a stale pull can neither regress a push still in
  flight nor re-apply a position this device just pushed itself), and stashes a genuinely newer
  value in `AppSettings.pendingRemoteReadingPosition` rather than applying it immediately —
  swallowing any failure (including a 404 from a server predating this endpoint) since this is a
  nicety layered on the sync pass, never allowed to break the feeds/tags/articles pull that
  actually matters. That last-writer-wins gate/stash rule is factored into
  `ReadingPositionSync.applyRemoteUpdate(articleId:updatedAt:settings:)`, a single source of truth
  shared by `syncReadingPosition`'s pull above AND `ReadingPositionLiveSync`'s live push below, so a
  remote update is applied identically regardless of which route delivered it.
  `ReadingPositionLiveSync` (started/stopped alongside `scenePhase` in `YanaApp.swift`, active only
  while foregrounded) holds a long-lived connection to the same per-user SSE feed
  `UpdateAndSync`/`JobEventsClient` already use for reload-job completion
  (`GET /api/v1/jobs/events`), watching for the `readingPosition` event `yana-server` publishes
  right after a `PATCH /api/v1/reading-position` commits (`src/lib/api/events.ts`/
  `src/app/api/v1/reading-position/route.ts` in the `yana-server` repo) — so another paired device's
  navigation shows up here within the live connection's latency instead of waiting for this
  device's next full sync. Best-effort like the rest of that SSE feed: a dropped/never-opened
  connection loses nothing but low latency, since the periodic pull above always eventually catches
  up regardless. That stashed value is applied — and consumed — by
  `ReaderAnchorController`/`TimelineModel`'s `jumpToSyncedTimelinePosition`, called ONLY from
  `applyTimeline()`'s first-load branch (a fresh app launch/session, before the user has navigated)
  by resolving the pulled server article id directly against `ArticleSummary.serverID` — never
  mid-session, which would yank the user off the article they're actively reading. This read side
  writes `timelineAnchorIdentifier`/`timelineAnchorServerID` directly rather than going through
  `TimelineAnchorWriter.record`, by design: it must never trigger another push, or two open devices
  would trade anchor writes forever (pinned by `ReaderAnchorControllerTests`). `ReaderAnchorController`
  (iOS) and `TimelineModel.anchorWriter` (Mac) remain separate, directly-testable read/write surfaces
  so the user-driven push path (`saveAnchor`/`recordOpenedArticle`/`selection`/`moveSelection`) and the
  self-heal/remote-apply read paths (`reanchorIndex`/`reanchorToCurrentArticle`/
  `jumpToSyncedTimelinePosition`) stay distinguishable in tests. Every one of these position-resolution
  lookups (`TimelinePageIndex.index`, `TimelineAnchor.index`, `TimelineOrder.isOrderedBefore`, the reader
  pager's neighbor/page-cache lookups in `ReaderArticleViewController`) prefers an exact `serverID`
  match over `identifier` when one is available (`TimelineIdentifiable.stableKey` in
  `Yana/Utilities/TimelineFiltering.swift`): `Article.identifier` is only a per-feed dedup key, so two
  different feeds can legitimately share one, and a plain identifier match could otherwise resolve —
  or cache — the wrong feed's article, which is what caused "going back" to occasionally land the
  reader on (or briefly render) a completely unrelated article.
- **Background refresh** (`Yana/Services/BackgroundRefreshManager.swift`): best-effort periodic
  `BGAppRefreshTask` + `BGProcessingTask`, registered at launch, rescheduled from the per-device
  `AppSettings.updateInterval` (`UpdateInterval` enum). `runRefresh` calls
  `SyncEngine.sync()` directly (in place of the old `AggregationService.updateAll()`) and posts a
  new-article notification via `NotificationService`/`NewArticleNotification` when enabled, the
  system authorized it, and the sync pulled down at least one new article summary — otherwise
  silent, matching the old behavior. On Mac Catalyst (no `BGTaskScheduler`), a cancellable
  repeating in-process `Task` loop (`scheduleMac`) drives periodic updates while the app is running
  instead. That loop is re-armed, not just armed once at launch (audit U4): `YanaApp.swift`'s
  `.onChange(of: appSettings.updateInterval)` calls `AppDelegate.rearmBackgroundRefresh()` →
  `BackgroundRefreshManager.schedule()`, which cancels and restarts `macRefreshLoop` at the new
  interval, and switching the interval to `.off` takes the `guard secondsProvider() != nil else`
  branch, which cancels the loop outright instead of leaving a stale one running against an
  abandoned setting. Returning to the foreground also triggers an out-of-band run: `scenePhase`
  going `.active` calls `AppDelegate.refreshOnFocus()` → `runNow()`, so a user who left the app
  backgrounded for a while sees fresh content immediately rather than waiting for the loop's own
  tick. Both `runNow()` and the loop's per-tick `runRefresh` call pass
  `postsNotification: UIApplication.shared.applicationState != .active`, so a foreground-triggered
  run (focus, launch) never fires a "new articles arrived" system notification while the user is
  already looking at the window — that noise is reserved for runs that actually happened while
  backgrounded.
- **Reader** (`Yana/Reader/`): a native SwiftUI body renderer (no WebView) — **unaffected by this
  rework's networking changes**. Article bodies are stored as a closed, typed `[Block]` model
  (`Block.swift`) — paragraphs/headings/lists/blockquotes/images/embeds/code/dividers, with styled
  `InlineRun`s — and rendered by `ArticleBlockView` (per-block SwiftUI; `AttributedString` text for
  selection/Dynamic Type/accessibility; images loaded from the local `ImageStore` by `yana-img://`
  ref (tapping an image opens it full-screen with pinch-to-zoom, double-tap-to-zoom and swipe-down-
  to-dismiss via `ReaderImageViewerViewController`); video embeds shown as tappable poster cards and
  tweet embeds as text cards — tapping a video plays it full-screen in-app via
  `ReaderVideoPlayerViewController` (YouTube/Dailymotion in a `WKWebView` privacy-mode player; a
  direct HLS/MP4 stream such as a Reddit `v.redd.it` post in a native `AVPlayerViewController`),
  while tweets/unplayable embeds open externally. **How the player is loaded is per-provider,
  decided by `ReaderVideoPlayerViewController.requiresEmbedderContext(_:)` — do not unify the two
  branches.** Dailymotion (and anything else) loads **top-level**, which makes the provider
  first-party so a `WKUserScript` can pre-seed its consent-notice localStorage flag; **YouTube must
  stay inside the `<iframe>` wrapper** (`html(embedURL:)`, based on `ReaderWeb.baseOrigin`) with the
  matching `origin=` parameter, since its `/embed/` endpoint refuses a top-level navigation with
  "Error 153." `ReaderHostView`/`ReaderScreen` is the SwiftUI bridge that reads the full lightweight
  index from `ArticleStore`, remembers scroll position, and hosts the Settings and Filter sheets. It
  wraps `ReaderArticleViewController` — a `UIPageViewController`-based pager with an opaque native nav
  bar, a bottom toolbar, and tap-to-hide full-screen mode — whose pages are each a
  `ReaderBlockViewController` (a `UIHostingController` wrapping `ArticleBlockView`, pull-to-refresh,
  which now triggers `ArticleActions.updateAll()` + `UpdateAndSync.pollForFreshContent` instead of the
  old on-device aggregation); each page's full `Article` is resolved lazily by `persistentID`. Body
  text size is driven by `ArticleTextSize`; links open in `SFSafariViewController` or the system
  browser via `ReaderLinkPolicy`. Read-aloud is handled by `ReaderSpeechController` (AVSpeechSynthesizer;
  matches the article's detected language, keeps playing when locked/backgrounded, wires up Now
  Playing / remote controls). **Where blocks come from now:** production content arrives already
  parsed into `[Block]` from the server via `BlockWireDecoding`'s `WireDocument`.
  **There is no HTML anywhere in this client any more, and no HTML parser.** `BlockParser`
  (`Yana/Reader/BlockParser.swift`) is now only `plainText(_:)`, which flattens any `[Block]` body
  to the search/read-aloud surface (set by the `Article.blocks` setter) — load-bearing for every
  article. Its former `blocks(fromHTML:)` half, the `Article.content` column it read, the
  `BlockMigration` sweep that drove it, and the **SwiftSoup dependency** behind it are all deleted;
  the DEBUG-only `DebugSeed`/`ScreenshotSeed` fixtures now author `[Block]` values directly, the
  same shape the server delivers. If you find yourself wanting an HTML parser here, the content
  should be arriving from the server as blocks instead.
- **Views** (`Yana/Views/`): feed/tag/AI-provider **management moved entirely to the server's own
  web UI**. `ManagementWebView` (`Yana/Views/ManagementWebView.swift`) hosts it in a `WKWebView`
  that bootstraps a fresh, short-lived, single-use server session on every appearance — see
  **Auth / device pairing** above for the full `POST /api/v1/auth/webview-session-token` /
  `GET /webview-session?token=...` exchange this drives, and why it replaced the earlier reused-
  cookie-session approach; `SettingsScreenView`'s "Manage Server" row and the
  Mac's create-feed sheet both push/present it at different paths (the site root `/` -- the view's
  default -- and `/feeds/new`).
  `FeedsView`/`TagsView`/`FeedEditorView`/`FeedEditorModel`/`AggregatorOptionsForm`/`SelectorListView`/
  `SelectorSuggester` and the four AI-provider/Reddit/YouTube Settings sections are all **deleted**;
  so is OPML import/export (`OPMLCodec`/`FeedPortability`) — there is no client-side feed
  configuration to import/export any more. `SettingsScreenView` (iOS, a single scrolling `Form`) is
  now: the Manage row, `ReaderSettingsSection`, `AIModeSettingsSection` (the 2-option picker, shared
  verbatim with onboarding's AI step), `NotificationsSettingsSection`, `LibrarySettingsSection` (just
  the `UpdateInterval` picker — retention is server-side only now, so there's no client retention
  setting either), and `AboutSettingsSection` (source/issue links, NetNewsWire credit, version, a
  "Show Welcome Screen Again" restart action, and — only for devices classified as
  pre-server-migration users — a "Server Update Notice" restore action). A searchable
  `ArticleListView` (reached from the reader's list button, not a "config hub" any more) still exists
  unchanged: full-text search over title/plainText/author/feed name, swipe-to-star/reload (star is
  optimistic-local + `ArticleActions.setStarred`; reload calls `ArticleActions.reload` then
  `UpdateAndSync.pollForReloadedContent`), swipe-to-delete (local-only), and the same `TagFilterView`
  filter sheet. The hidden **Diagnostics** entry point (`DiagnosticsReveal`, the About → Version
  five-tap gesture, and the `SyncLogView` screen it used to unlock) is gone entirely — removed along
  with `SettingsPane.diagnostics` once CloudKit sync was removed, since there was no longer a
  diagnostics screen for it to reveal.
- **Pre-server-migration notice** (`Yana/Models/ServerMigrationEligibility.swift`,
  `Yana/Views/ServerMigrationNoticeView.swift`, `Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift`):
  a one-time classification + notice for devices that completed onboarding before this rework ever
  shipped (i.e. under the old, fully-local, server-free flow). `ServerMigrationEligibility.evaluate`
  runs exactly once per device (`AppSettings.hasEvaluatedServerMigrationEligibility` guards
  re-evaluation forever after) and classifies a device as `isPreServerMigrationUser` purely from
  whether it had *already* completed onboarding — a fresh install finishing onboarding after this
  code shipped is never classified as pre-migration. `ContentView` auto-shows the notice
  (`.fullScreenCover` on iOS, a singleton `WindowID.serverNotice` window on Mac) once per device
  until dismissed, and `AboutSettingsSection` exposes a "Server Update Notice" row to reopen it for
  devices that were classified this way.
- **Onboarding / re-pairing** (`Yana/Views/WelcomeView.swift`,
  `Yana/Views/Onboarding/OnboardingServerPage.swift`, `Yana/Views/Onboarding/OnboardingAIModePage.swift`):
  `WelcomeView` is now a 3-step paged coordinator — `.welcome` (feature highlights), `.server`
  (`OnboardingServerPage`: enter a server URL, then pair via a `DevicePairingView` sheet — the same
  flow Settings uses to re-pair), `.aiMode` (`OnboardingAIModePage`). `OnboardingAIModePage` is
  deliberately its own small implementation rather than reusing `AIModeSettingsSection` verbatim:
  that component is a `Section`, built to live inside a `Form`/`List`, which always expands to fill
  whatever height it's given — wrapping it in a `Form` here would leave the same "sparse content,
  huge dead space below it" problem `OnboardingServerPage` had, so this page mirrors that page's
  content-sized, card-styled, centered layout instead, keeping every onboarding step visually
  consistent. Finishing kicks off a first foreground `SyncEngine.sync()`.
  `ContentView`'s `.onAppear` gate now covers two cases, not one: a device that never completed
  onboarding starts at `.welcome`; a device that **did** complete onboarding but currently has no
  valid session (`AuthenticatedClient.current() == nil` — pairing revoked from another device, or the
  Keychain was cleared) re-enters `WelcomeView` starting at `.server` instead of restarting from
  `.welcome`.
- **First-sync gate and pairing transitions** (`Yana/Services/InitialSyncGate.swift`,
  `Yana/Services/PairingSync.swift`, `Yana/Services/ServerDisconnect.swift`,
  `Yana/Views/InitialSyncLoadingView.swift`, `Yana/Views/InitialSyncFailedView.swift`):
  `InitialSyncGate.run` blocks the reader behind `InitialSyncLoadingView` for a device's very first
  sync after pairing, because the timeline sorts by the article's original date rather than import
  order — a large historical backfill landing in ~200-article pages can insert new unread articles
  anywhere in the currently-visible range, which made swiping through the timeline jump to unrelated
  articles while pages were still trickling in. It retries the first `SyncEngine.sync()` call up to
  `maxAttempts` (5, with a `retryDelay` between tries) since a transient failure partway through must
  not be mistaken for done — that used to leave older pages to arrive later via the ordinary
  background path with no gate left to catch them. A `YanaAPIClientError.unauthorized` during those
  retries gives up immediately without setting the failure state (the token is already dead;
  `ContentView`'s re-pairing gate picks it up on its own), while every other exhausted attempt sets
  `AppState.initialSyncFailed = true` so the reader shows `InitialSyncFailedView`'s "Try Again"
  action instead of silently rendering the empty-library "add your first feed" state against a
  server that actually has content (audit U3). `run` takes an optional `syncOnce` closure as a test
  seam, defaulting to a real `SyncEngine(container:client:).sync()` call. `PairingSync
  .resetAndFullSync` wipes the local mirror and re-runs this gate's blocking branch whenever a
  (re-)pairing hands the app a fresh Bearer token — shared by onboarding's "Continue" and Settings'
  "change server" flow, since either could point at a different server than whatever was already
  mirrored locally. `ServerDisconnect.disconnect` mirrors that transition in reverse: deletes the
  stored token, clears the server address, wipes the mirror, and falls back into the same
  demo-content mode `OnboardingServerPage`'s "Skip for now" offers, clearing `hasCompletedInitialSync`
  too so a later re-pair goes through the loading screen again instead of silently skipping it.
- **Mac Catalyst windowing** (`Yana/Reader/Mac/`): structurally unchanged by this rework — `MacRootView`
  is still a permanent two-column `NavigationSplitView` (article-list sidebar + reader detail), with
  Welcome/Settings/the pre-server-migration notice as separate singleton `WindowGroup`s
  (`WindowID.welcome`/`.settings`/`.serverNotice`, each bound `for: Bool.self` and always opened with
  the constant `true` so SwiftUI dedupes to one window). What changed is **content, not structure**:
  `MacSettingsWindow`'s sidebar panes are now `SettingsPane.general/reader/manage/ai/about` (no more
  `.feeds`/`.tags`/`.integrations`/`.diagnostics` — `.manage` pushes the same `ManagementWebView` iOS
  uses; the hidden-diagnostics reveal was removed entirely, see **Views**). Creating a
  feed is a sheet presenting `ManagementWebView(path: "/feeds/new")`, not the deleted
  `FeedEditorView`/`WindowID.feedEditor`. Everything else — the Mail-style two-pane keyboard focus
  model (`MacFocusPane`), the sidebar's programmatic-scroll-follow (`SidebarScrollRequest`,
  `.scrollPosition(id:anchor:)`), the remembered sidebar width (`AppSettings.macSidebarWidth`,
  `SidebarWidth`), and the `MacToolbarStyle` chrome-convention helper — is unaffected
  and still applies exactly as before.
- **Utilities** (`Yana/Utilities/`): constants and extensions.

### Project structure

- `Yana/YanaApp.swift` — app entry point; owns the shared `AppContainer.shared` `ModelContainer`
  (`Feed`/`Tag`/`Article` only — no `cloudKitDatabase` configuration) and an `AppDelegate`
  (`UIApplicationDelegateAdaptor`) that registers/schedules background refresh on launch. The scene's
  `.task` starts `ArticleStore` and then — if `AuthenticatedClient.current()`
  resolves a client — runs a foreground `SyncEngine.sync()`, swallowing any error (a spotty
  connection at launch must never block first paint or crash the app). It deliberately runs **no**
  data-repair sweeps: the `BlockMigration` (legacy HTML → blocks) and `ArticleDedup` (duplicate
  `serverID` rows) passes that used to run here on every launch were self-terminating fixes for
  bugs that no longer exist, and the dedup pass re-read the whole article table each launch to find
  nothing. Gate any future one-off repair behind a one-shot `AppSettings` flag instead.
- `Yana/ContentView.swift` — root view (opens directly into the reader on iPhone/iPad; `MacRootView`
  on the Mac idiom). Presents `WelcomeView` for onboarding/re-pairing and
  `ServerMigrationNoticeView` for the one-time pre-migration notice, both gated and skippable under
  the `-UITEST_SKIP_ONBOARDING` / `-UITEST_SCREENSHOTS` launch arguments (see **Onboarding /
  re-pairing** above for the exact gating logic).
- `Yana/Models/AppState.swift` — thin observable UI state (timeline anchor, tag filter, errors,
  welcome/server-notice presentation flags)
- `Yana/Utilities/Constants.swift` — app constants
- `LICENSE` — MIT license
- `docs/app-store/` — App Store listing copy: English + German descriptions (`description-*.md`, ≤4000 chars each) and keyword lines (`keywords-*.txt`, ≤100 chars each), plus a `README.md` documenting the field format
- `docs/site/` — the GitHub Pages marketing + legal site (`index.html` + `privacy`/`impressum`/`terms`/`server`, `assets/`), deployed to `yana.fa-krug.de` by `.github/workflows/pages.yml` (see **Website** under Commands)

### Key patterns

- **Server-backed, offline-first:** all content is aggregated by a self-hosted Yana Server; this app
  is a thin client that pairs once (device pairing, Bearer token in Keychain) and then mirrors the
  server's article/feed state into local SwiftData for instant offline browsing, pushing user actions
  back up as API calls. `AuthenticatedClient.current() == nil` ("not paired") is treated as a normal,
  silent state throughout — sync, background refresh, and the reader's action handlers all no-op
  rather than error.
- **The timeline mirrors the server's append-only order, and nothing else reorders it:** the single
  source of truth is `TimelineOrder` (`Yana/Utilities/TimelineFiltering.swift`) —
  `Article.createdAt` ascending (the server's own insertion-order key) with `Article.serverID` as
  the tiebreak. Every ordering site must agree with it: `ArticleSummaryLoader`'s `SortDescriptor`s
  (`load()` and `lightDescriptor`), `SummaryIndexMerge`'s splice, and the filters (which only ever
  remove rows, never reorder). Three rules, each of which was violated at some point and produced a
  timeline that reshuffled under the user:
  - **Read state must not sort.** It used to be the primary key (`Article.readRank`, read block
    first, then unread), so an article moved between blocks the instant it was marked read — which
    happens the moment it becomes current. Every swipe therefore reordered the list, back-navigation
    landed on a different article each time, and paging back through already-read history was
    incoherent. The `readRank` mirror column, its index, and the `Article.setRead(_:)` setter that
    maintained it are all deleted — assign `Article.read` directly. The band-aid this replaces,
    `TimelinePinning` (which lifted the displayed article back to its as-if-unread slot), is deleted.
  - **`Article.date` must not sort.** It's the feed's own publish timestamp, display-only, and a feed
    can backfill it out of order, which would retroactively move an article the user already paged past.
  - **`serverID` is a required tiebreak, not a nicety.** The server stamps `createdAt` with
    whole-second precision (`unixepoch()`), so one aggregation run gives hundreds of articles the same
    value; without the tiebreak those ties have no defined order and the DB's arbitrary choice need
    not match `TimelineOrder`'s, so a single splice could reorder a whole batch.

  An article is still marked read automatically the moment it becomes the current/displayed one (an
  iOS pager swipe completing, opening it from the article list, or a Mac sidebar selection change —
  `ArticleWrites.markRead`); that is now purely a display/badge change. The server can upgrade a
  synced article from unread to read (read on another device) but a sync pass can never downgrade an
  already-locally-read article back to unread (`SyncWriter.upsertSummaries`'s upgrade-only rule).
  Starring is a separate, orthogonal `Article.starred` boolean with its own "Starred Only"
  quick-filter, and likewise never affects order.
- **Tags are a live join, not a snapshot:** `Feed.tagIDs` is refreshed from the server on every
  `/feeds` fetch, and the timeline's tag/feed/starred filtering (`Yana/Utilities/TimelineFiltering.swift`
  — `TagFilter`/`FeedFilter`/`StarredFilter`, applied identically to the full `Article` and the
  lightweight `ArticleSummary`) always reflects the feed's *current* tag membership. This replaces the
  old per-article "tags snapshotted at import time" model. **Starred is a plain `Article.starred`
  boolean**, not tag membership — there is no more built-in "Starred" tag; the timeline filter has a
  dedicated "Starred Only" quick-filter toggle instead (`AppSettings.starredOnly`).
- **Update vs. reload, now server-triggered:** two distinct semantics, reflected in the action labels,
  both of which now only *trigger* server-side work and must poll to see the result (a POST/PATCH ack
  is not the content itself — see `UpdateAndSync`). **"Update"** (the reader's pull-down gesture, "Update
  All") calls `ArticleActions.updateAll()` (`POST /aggregate`, all enabled feeds) then
  `UpdateAndSync.pollForFreshContent` (polls `GET /api/v1/runs/:id` until the run finishes, then
  syncs once — see **Actions** above for the transient-failure handling).
  **"Reload"** (the `ArticleListView` swipe, the reader overflow menu) calls
  `ArticleActions.reload(articleServerID:)` (`POST /articles/:id/reload`, that article only) then
  `UpdateAndSync.pollForReloadedContent` (waits on the `/api/v1/jobs/events` SSE stream for that
  job's completion, falling back to a single direct re-fetch of `/articles/:id/content` if no
  matching event arrives in time — not through `SyncEngine`'s backfill; see **Actions** above for
  why). There is no more
  client-side per-feed update/reload or "auto-run a newly created feed" — feed creation/management
  happens entirely in the server's web UI now.
- **SwiftData source of truth, sync writes it:** `SyncEngine`/`SyncWriter` write; views read
  lightweight metadata via `ArticleStore` (backed by SwiftData) rather than per-view `@Query`s.
- **`propertiesToFetch` is a partial fault, not a projection — under-listing it costs more than
  listing nothing.** A column left out is not skipped; it is filled by a per-row fault the first
  time anything touches it. The light timeline descriptors once omitted `serverID`/`starred`/`read`
  while `ArticleSummary.init` read all three, so the full index load faulted once per row. Every
  descriptor that builds summaries now uses `ArticleSummary.fetchedProperties`; keep that list in
  lockstep with the initializer. The heavy body columns (`blockData`/`plainText`/`summary`/
  `content`) are the ones that must genuinely stay out. The same applies to
  `relationshipKeyPathsForPrefetching`: prefetch only relationships something reads — those
  descriptors used to prefetch the never-populated `Article.tags` on every fetch.
- **Swift 6:** strict concurrency with `@MainActor` annotations throughout.
- **`@ModelActor` runs on its caller's thread — always wrap it in `OffMainActor.run`.** A
  `@ModelActor` does **not** own a background queue: SwiftData's `DefaultSerialModelExecutor` runs
  enqueued jobs inline on the calling thread, so `await someModelActor.work()` from a `@MainActor`
  type performs the whole fetch/save **on the main thread**. Constructing the actor off-main does not
  help — the thread is chosen at the `await`, not at `init`. Declaring a type `@ModelActor` therefore
  says nothing about which thread it runs on; only the caller does. Every main-actor → `@ModelActor`
  call must go through `OffMainActor.run` (`Yana/Utilities/OffMainActor.swift`):
  `ArticleStore.fullLoad`/`publishFastDataset`, `SyncEngine`'s calls into `SyncWriter`,
  `UpdateAndSync.pollForReloadedContent`'s `applyContent` call. `OffMainActorTests` pins the executor
  behaviour (including the "created off-main is not enough" case) so a future SwiftData change is
  caught, and `SyncReactionMainThreadTests` measures main-actor responsiveness across the sync-reaction
  chain — a regression there shows up as a stall, not a wrong value.
- **Platform:** iOS 26.0+ (iPhone, iPad, and Mac Catalyst).

### Tests
- `YanaTests/` — unit tests using the Swift Testing framework (`import Testing`); as of this
  change, 404 tests in 92 suites, all passing. (An earlier pass had dropped to 381 tests in 90
  suites from a prior 406 by deleting dead-code and legacy-HTML suites — ones that only exercised
  orphaned helpers such as `CredentialTesterTests`, `NameSearchTests`, `ArticleSearchTests`,
  `CrossFadeTests`, `UpdateProgressTests`, `ArticleHeaderLogoTests`, plus
  `BlockParserTests`/`GiphyBlockReproTests`, which covered the deleted HTML→blocks parser and went
  with the code they tested.) The audit-fix batch since then added further coverage in existing and
  new suites — `InitialSyncGateTests` (the retry/give-up state machine and its `syncOnce` seam, a
  new suite) among them — plus `ArticleWritesTests` (`setRead`'s no-op-when-unchanged and
  queue-on-failure behavior), `DevicePairingTests` (`classify`'s four failure modes), and
  `BackgroundRefreshManagerTests` (the Mac loop's re-arm/cancel-on-`.off` behavior), bringing the
  suite back up to its current 404/92.
- `YanaTests/TestHelper.swift` — shared test utilities
- `YanaTests/SyncWriterTests.swift`/`SyncEngineTests.swift`/`RunBoundedTests.swift` — pin `SyncWriter`'s
  upsert/removal/content-apply behavior directly (including the `IN`-predicate `TERNARY`-crash trap
  the removal path works around) and `runBounded`'s concurrency bound.
  `YanaTests/AuthenticatedClientTests.swift`/`DevicePairingTests.swift`/`YanaAPIClientTests.swift`/
  `BlockWireDecodingTests.swift` cover the new networking/auth stack.
- `YanaTests/ArticleStoreIncrementalTests.swift`/`SyncReactionMainThreadTests.swift` — assert
  `ArticleStore`'s splice-vs-full-reload behavior and main-thread responsiveness across the sync
  chain; the latter's comments explicitly note what this rework removed (`ImageSync`/`StoredImage`,
  `AggregationWriter.referencedImageSnapshotForPruning()`) so a reader isn't left hunting for types
  that no longer exist.
- `YanaTests/ServerMigrationEligibilityTests.swift` — pure state-machine tests for the pre-migration
  notice. (The hidden-diagnostics reveal gesture this used to sit alongside,
  `DiagnosticsRevealTests.swift`, was deleted with the feature it tested — see **Views**.)
- `YanaUITests/YanaUITests.swift` / `ScreenshotUITests.swift` / `MacScreenshotUITests.swift` — UI
  tests using XCTest. The iPhone-side identifier lookups (`"settings.manage"`, `"settings.aiSection"`)
  were fixed to match the server-API client rework and the full iOS Simulator suite passes, including
  `ScreenshotUITests.testCaptureScreenshots` and `YanaUITests.testSettingsRestoreShowsWelcomeAgain`.
  `MacScreenshotUITests.swift` selects the Settings sidebar pane by its current raw values
  (`general/reader/manage/ai/about`, matching `SettingsPane` in `Yana/Reader/Mac/WindowID.swift`) —
  the stale `"feeds"` lookup this used to carry was fixed. Mac Catalyst tests aren't part of the iOS
  Simulator `xcodebuild test` run above, so this suite is verified separately.
- Run tests: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- All tests use `@MainActor` for safe concurrency
- **UI-test isolation:** XCTest reuses **one** simulator app container across test classes and runs
  them alphabetically, so `ScreenshotUITests` runs first and seeds a whole fixture library via
  `ScreenshotSeed` — which persists, because that seeder is idempotent and bails once any `Feed`
  exists. Any test asserting on an empty library (or a short Settings form) must therefore pass
  **`-UITEST_RESET_LIBRARY`** (`Yana/Utilities/UITestReset.swift`, DEBUG-only: wipes
  articles/feeds/tags and both timeline anchors at launch, before the seeds run). Without it a test
  passes alone and fails in a full run. `ScreenshotSeed` also installs a **fake pairing**
  (`serverBaseURL` in `UserDefaults` + a fixture token in the Keychain, so the screenshot run's
  Settings form shows the "Manage Server" row), and neither of those lives in the SwiftData
  store — so the same reset also clears the token, `serverBaseURL`, `hasSkippedServerPairing`, and
  `hasCompletedInitialSync`. A test launched with this argument is therefore **unpaired**: don't
  assert on pairing-gated UI such as the `settings.manage` row (use the unconditional
  `settings.server` row to prove Settings opened).
- **Scrolling the Settings form in a UI test:** don't use `app.swipeUp()`. It swipes from the screen
  centre, which lands on control rows and drags a *control value* instead of scrolling, so the form
  stalls and later sections are never reached (an intermittent failure). Use
  `YanaUITests.scrollToSettingsRow(_:in:)`, which drags along the leading edge over the inert row
  labels and waits for `isHittable` rather than `exists`.

### User-facing text style
- **All user-facing copy — in-app strings, App Store descriptions, release notes, marketing site
  copy, onboarding text — must read as naturally written prose, not as AI-generated text.** Write
  in flowing sentences and paragraphs. **Never use bullet points, numbered lists, or em/en dashes
  (—, –) as a rhetorical device** to bolt two clauses together — use a period, comma, or "and"/"but"
  instead, the way a person drafting marketing copy actually writes. This applies to English and
  German equally. See `docs/app-store/description-{en,de}.md` and
  `docs/app-store/release-notes-*.md` for the target tone and structure.
- This does **not** apply to code comments, commit messages, or this file (`CLAUDE.md`) — only to
  text a user of the app or website will actually read.

### Translations
- Source language: English (`en`)
- Supported languages: English (`en`), German (`de`). Registered in `project.yml` under `options.knownRegions`.
- String catalog: `Yana/Resources/Localizable.xcstrings` — Xcode string catalog format (JSON)
- Views use `String(localized:)` for computed property strings and string literals with `LocalizedStringKey` for SwiftUI text
- All user-facing strings should be localizable
- **ALWAYS create translations.** Whenever you add or change a user-facing string, you MUST add the corresponding entry to `Localizable.xcstrings` with a translation for **every** supported language (currently `de`), each marked `"state" : "translated"`. Never leave a new string English-only or untranslated. German follows Apple's localization style (infinitive for actions/instructions, e.g. "Im Browser öffnen", "In den Einstellungen hinzufügen"; no "Du"/"Sie"). When adding a new supported language, add it to `options.knownRegions` in `project.yml`, backfill translations for all existing strings, and update this list.
- **Count-bearing strings need an explicit `en` plural block — English is NOT free.** The catalog is
  hand-maintained, so a key with no `en` localization is not written to `en.lproj` at all and lookup
  falls back to the **key itself**. For `"%lld articles"` that renders "1 articles"; for a key using
  automatic grammar agreement (`^[…](inflect: true)`) the fallback path does not process the markup
  either, so the literal `^[3 new article](inflect: true)` reaches the UI. Both shipped. So: any
  string with a countable noun next to a number needs `variations.plural.{one,other}` for `en` *and*
  for every other language whose forms differ — never rely on the source language falling back, and
  never rely on `inflect: true`. `"%lld entries"` is the reference shape. When the count is not the
  first argument (`"Delete “%@”? Its %lld articles …"`) a whole-string plural variation keys on the
  wrong argument; use a `substitutions` entry (`argNum`, `formatSpecifier`, `%#@name@` in the value,
  `%arg` inside the variation) — see `"Imported %lld feeds, skipped %lld."`. A bare number with no
  noun (`"Daily Limit: %lld"`) or a unit abbreviation (`"%lld min"`, `"%llds"`) needs nothing.
  `YanaTests/PluralAgreementTests.swift` renders each of these at count 1 and 2 per language; note
  it pins the language via an explicit `.lproj` bundle, because the simulator is not necessarily
  English and `locale:` alone selects plural *rules*, not the localization.

## Planned Features

### Core (MVP)
1. **Device pairing** — pair with a self-hosted Yana Server via a WebView-based sign-in flow; store the resulting Bearer token in Keychain
2. **Server-driven aggregation** — the server fetches & parses feeds; this app syncs the resulting articles/feeds down via `/api/v1/articles/sync` and `/api/v1/feeds`, storing everything locally in SwiftData for offline access
3. **Endless timeline** — single stream of all articles in the server's own append-only order (`createdAt`, then `serverID`; see **Key patterns**), swiped both directions, position remembered (device-local)
4. **Tag filter** — filter the timeline by toggling tags (all on by default; includes an "Untagged" entry); tag membership is a live join to the feed's current server-side tags, not a per-article snapshot
5. **Article detail** — render the article's native `[Block]` body (arriving pre-parsed from the server) in the swipe reader
6. **Starred** — star/unstar an article (`Article.starred`, a plain boolean synced via `PATCH /articles/:id`); starred articles are exempt from server-side retention
7. **Update / Reload** — trigger the server's aggregation run (pull-down on the reader, "Update All") or a single article's re-fetch (swipe/reader overflow menu "Reload"), then poll `/articles/sync` or `/articles/:id/content` to pull the result down
8. **Retention** — server-side only; the client mirrors whatever the server decides to keep, receiving deletions through `/articles/sync`'s `removed` list
9. **Background refresh** — best-effort periodic sync via `BGAppRefreshTask`/`BGProcessingTask`
10. **AI summarization** — optional, per-device choice between the server's configured AI provider (`POST /api/v1/ai/prompt`) or on-device Apple Intelligence

### Enhanced
- **Search** ✅ — full-text search across articles (title/plainText/author/feed name) via the reader's `ArticleListView`
- **Feed/tag management** ✅ — moved entirely to the server's own web UI, reached from Settings (`ManagementWebView`) via an embedded WebView that bootstraps a fresh, short-lived, single-use server session token on every appearance
- **Notifications** ✅ — opt-in (off by default) local notification with the new-article count after a background sync
- **Read-aloud** ✅ — `ReaderSpeechController` reads articles aloud with a voice matching the article's language, continues from the lock screen / Control Center, and exposes a voice picker in the Reader settings section
- **Offline-first sync** ✅ — an authenticated device eagerly mirrors the server's full article/feed state (including block content and every referenced image) into local SwiftData, so browsing and full-text search both work with no network round-trip once synced; a paired-but-offline device still reads everything it already has
- **AI mode choice** ✅ — per-device `AIMode` (server-configured provider vs. on-device Apple Intelligence), with live on-device availability shown when Apple Intelligence is selected
- **Open source** ✅ — MIT-licensed (`LICENSE`); Settings › About links the source repo and issue board, and credits NetNewsWire for the reader view; App Store copy lives under `docs/app-store/`
- **Biometric auth** — Face ID / Touch ID protection (same pattern as MySquad)
- **Multiple libraries** — support multiple independent local feed libraries/profiles
- **Share extension** — share URLs to add as feeds
- **iPad layout** — multi-column NavigationSplitView for iPad
- **Widgets** — home screen widgets
