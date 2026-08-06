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
reuses the pairing session's cookies. Yana is open source under the MIT license (`LICENSE`); the
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
  in the Fastfile. **Same known stale-identifier debt as the iPhone lane:** the test still selects
  the Settings sidebar pane by its old raw value `"feeds"` (`mac.settings.pane.feeds`), but
  `SettingsPane` (`Yana/Reader/Mac/WindowID.swift`) no longer has a `.feeds` case — the pane set is
  now `general, reader, manage, ai, about`. Not fixed by this plan; see **Tests**.
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
  rework shipped). `Feed.aggregator: String` is the server's aggregator key (e.g. `"reddit"`,
  `"heise"`), display-only — nothing client-side branches on it, since there is no native feed
  creation/editing left to special-case. `Feed.tagIDs: [Int]` is a **live** join to the server's tag
  ids, refreshed on every `/feeds` fetch (unlike the old per-article tag snapshot this replaced, tag
  membership always reflects the feed's current server-side state — see **Key patterns**).
  `Article.starred: Bool` is a plain field (no more built-in "Starred" tag or `Tag.isBuiltIn`).
  `Article.serverID: Int?` is the sync identity `SyncWriter` upserts/removes/backfills by.
  `Article.hasContent: Bool` tracks whether `/articles/:id/content` has landed yet for this row,
  driving the sync engine's backfill retry. `Article.read: Bool` and `Article.readRank: Int` track
  read state and drive primary timeline sort (never assign directly — use `Article.setRead(_:)`
  instead). `Article.blocks` (computed from `blockData`) is unchanged
  from before — see **Reader**.
- **Networking** (`Yana/Networking/`): `YanaAPIClient` (a thin typed wrapper over every
  `/api/v1/**` route — `get`/`patch`/`post`/`getRaw`, Bearer-token auth, ISO-8601 date decoding,
  decodes the server's `{ error: { code, message } }` envelope into `YanaAPIError` on failure) and
  `BlockWireDecoding` (`WireDocument`/`WireBlockBox`/`WireInlineRun`: a custom `Decodable` translation
  layer that turns the server's `type`-discriminated block JSON — matching
  `yana-server/src/lib/aggregators/blocks/schema.ts` — into the app's existing `Block`/`InlineRun`
  enum. `Block` itself keeps its compiler-synthesized `Codable`, which encodes differently, so this
  is a separate decode path, not a `Block` extension).
- **Auth / device pairing** (`Yana/Services/DevicePairing.swift`, `Yana/Views/DevicePairingView.swift`,
  `Yana/Services/CookieMigration.swift`, `Yana/Services/KeychainService.swift`,
  `Yana/Services/AuthenticatedClient.swift`): `DevicePairing`
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
  which intercepts the callback scheme directly, but kept since it documents the scheme in use). The
  trade-off: this session's cookies land in Safari's shared cookie jar (`HTTPCookieStorage.shared`),
  not the `WKWebsiteDataStore` `ManagementWebView` reads from — the two are entirely separate on iOS
  with no automatic sharing — so `CookieMigration.copySharedCookies(for:)` copies the resulting
  session cookies into `WKWebsiteDataStore.default()`'s cookie store right after a successful
  pairing, preserving the "no second login" behavior `ManagementWebView` depends on. On success the
  token is stored via `KeychainService.saveDeviceToken` — the Keychain service is now just
  `saveDeviceToken`/`loadDeviceToken`/`deleteDeviceToken` over one key, written with
  `kSecAttrSynchronizable: false` (device-local; no more per-provider API keys, no more iCloud
  Keychain sync). `AuthenticatedClient.current()` resolves the app's current `YanaAPIClient?` from
  `AppSettings.serverBaseURL` + the stored token; `nil` means "not paired yet" and every call site
  (the launch-time sync, `BackgroundRefreshManager`, the reader's action handlers) treats that as
  "nothing to do," not an error.
- **Sync** (`Yana/Services/SyncEngine.swift`, `Yana/Services/SyncWriter.swift`): the orchestrator +
  write-path pair that replaced `AggregationService`/`AggregationWriter` and the entire
  `Yana/Aggregators/` tree (deleted wholesale — no more `AggregatorType`, `AggregatorOptions`,
  per-source scraper types, or `AggregatorRegistry`). `Yana/Services/ArticleSearch.swift` (the
  older in-memory case/diacritic-insensitive matcher) survived the deletion but is now exercised
  only by its own tests — production search runs through `ArticleListSearch`'s `#Predicate`-backed
  fetch instead (see **Views** below); it predates this rework and isn't part of its scope.
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
  just retry on the next sync pass. `SyncWriter` (`@ModelActor`) does the actual `ModelContext`
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
  server does the re-fetch asynchronously), so `UpdateAndSync` follows up: `pollForFreshContent`
  bounded-backoff-retries `SyncEngine.sync()` (worst case ~9s) until a pass reports any change, used
  by the reader's pull-down / "Update All" flow; `pollForReloadedContent` instead re-fetches one
  article's content directly on each attempt (bypassing `SyncEngine`'s `hasContent`-gated backfill,
  which — once triggered prematurely mid-poll — would permanently block any later retry, since
  nothing else ever resets `hasContent` back to `false`), overwriting on every attempt rather than
  stopping at the first success, since there's no reliable "did it actually change" signal. Starring
  and marking read are both optimistic, funneled through the shared `ArticleWrites` facade — flip the
  local flag and save immediately, then fire the PATCH; on failure the change is enqueued into
  `PendingWriteQueue` (backed by `AppSettings.pendingWrites`) instead of being rolled back, and
  `SyncEngine.sync()` retries every queued write opportunistically before its normal pull. Both stay
  silently local-only when not paired.
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
  Settings-UI helper it drove — only the shared `CredentialTestError` enum survives, used by
  nothing but its own tests). `ServerAISummaryProvider` calls
  `POST /api/v1/ai/prompt` with a fixed summarize prompt against whatever provider the server is
  configured with; any failure (rate limit, no provider configured, provider error) degrades to
  `nil` — "no summary available" is an expected, silent outcome, never a user-facing error.
  `AppleIntelligenceSummaryProvider` runs entirely on-device via `AppleIntelligenceChunkedSummarizer`
  (extracted from the former `AppleIntelligenceProcessor`, keeping only the summarize path — the
  improve-writing/translate paths and their `AIOptions`/`AggregatedArticle` plumbing are gone): the
  same chunk → per-chunk-summary → reduce map-reduce over the ~4096-token on-device context window,
  now with hardcoded generation knobs (temperature 0.3, 2000 max tokens) since the settings that used
  to feed them were deleted along with the network stack. `AISummaryReadiness.isReady(mode:)` gates
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
- **Timeline anchor** (`Yana/Services/TimelineAnchorWriter.swift`, `Yana/Reader/ReaderAnchorController.swift`,
  `Yana/Reader/Mac/TimelineModel.swift`): also much simpler post-CloudKit-removal than the old
  cross-device-sync design this file used to document. `TimelineAnchorWriter` just persists the
  current article's `identifier` to `AppSettings.timelineAnchorIdentifier` (device-local
  `UserDefaults`) — there is no push, no `NSUbiquitousKeyValueStore`, no synced UID, no
  no-ping-pong concern, because there is nothing to ping-pong with any more. `ReaderAnchorController`
  (iOS) and `TimelineModel.anchorWriter` (Mac) are still kept as separate, directly-testable
  read/write surfaces so `saveAnchor`/`recordOpenedArticle` (user-driven) and
  `reanchorIndex`/`reanchorToCurrentArticle` (self-heal on timeline mutation, resolving by
  identifier via `TimelinePageIndex`) stay distinguishable in tests, even though the sync layer that
  originally motivated the split is gone.
- **Background refresh** (`Yana/Services/BackgroundRefreshManager.swift`): best-effort periodic
  `BGAppRefreshTask` + `BGProcessingTask`, registered at launch, rescheduled from the per-device
  `AppSettings.updateInterval` (`UpdateInterval` enum). `runRefresh` now calls
  `SyncEngine.sync()` directly (in place of the old `AggregationService.updateAll()`) and posts a
  new-article notification via `NotificationService`/`NewArticleNotification` when enabled, the
  system authorized it, and the sync pulled down at least one new article summary — otherwise
  silent, matching the old behavior. On Mac Catalyst (no `BGTaskScheduler`), a repeating in-process
  `Task` loop plus a launch/window-focus `runNow()` cover the same ground, since the desktop model is
  "the app tends to stay open" rather than woken by the system.
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
  parsed into `[Block]` from the server via `BlockWireDecoding`'s `WireDocument` — `BlockParser`
  (`Yana/Reader/BlockParser.swift`, relocated here from the deleted `Aggregators/Utils/` since it's
  still load-bearing) no longer runs at import time. It still does two things: `BlockParser.plainText`
  derives every article's search/read-aloud plain-text surface from its blocks regardless of origin
  (set by the `Article.blocks` setter), and `BlockParser.blocks(fromHTML:)` now runs only for
  `BlockMigration`'s one-time sweep converting any surviving pre-migration legacy-HTML articles
  (`Article.content`) into native blocks, and for the DEBUG-only `DebugSeed`/`ScreenshotSeed` fixtures
  that still author their content as HTML for convenience.
- **Views** (`Yana/Views/`): feed/tag/AI-provider **management moved entirely to the server's own
  web UI**. `ManagementWebView` (`Yana/Views/ManagementWebView.swift`) hosts it in a `WKWebView`
  reusing the pairing flow's persistent cookie session (`WKWebsiteDataStore.default()`) so a user who
  just paired isn't asked to log in again; `SettingsScreenView`'s "Manage Feeds & Tags" row and the
  Mac's create-feed sheet both push/present it at different paths (`/feeds`, `/feeds/new`).
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
  flow Settings uses to re-pair), `.aiMode` (`OnboardingAIModePage`, just embedding
  `AIModeSettingsSection`). Finishing kicks off a first foreground `SyncEngine.sync()`.
  `ContentView`'s `.onAppear` gate now covers two cases, not one: a device that never completed
  onboarding starts at `.welcome`; a device that **did** complete onboarding but currently has no
  valid session (`AuthenticatedClient.current() == nil` — pairing revoked from another device, or the
  Keychain was cleared) re-enters `WelcomeView` starting at `.server` instead of restarting from
  `.welcome`.
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
  `SidebarWidth`), and the `MacToolbarStyle`/`MacFormStyle` chrome-convention helpers — is unaffected
  and still applies exactly as before.
- **Utilities** (`Yana/Utilities/`): constants and extensions.

### Project structure

- `Yana/YanaApp.swift` — app entry point; owns the shared `AppContainer.shared` `ModelContainer`
  (`Feed`/`Tag`/`Article` only — no `cloudKitDatabase` configuration) and an `AppDelegate`
  (`UIApplicationDelegateAdaptor`) that registers/schedules background refresh on launch. The scene's
  `.task` runs `BlockMigration` off the launch path, then — if `AuthenticatedClient.current()`
  resolves a client — a foreground `SyncEngine.sync()`, swallowing any error (a spotty connection at
  launch must never block first paint or crash the app).
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
- **Read state drives the primary sort:** the timeline sorts by `Article.readRank` (0=read,
  1=unread) then `Article.date` — the original article date reported by the source, not the
  device's import/sync time (`Article.createdAt`, which still exists but only drives
  `SyncWriter`'s content-backfill order) — read articles first (oldest→newest), then unread
  articles (oldest→newest), so the next unvisited article is always the boundary between the two
  blocks.
  An article is marked read automatically the moment it becomes the current/displayed one: an iOS
  pager swipe completing, opening it from the article list, or a Mac sidebar selection change
  (`ArticleWrites.markRead`). The server can upgrade a synced article from unread to read (read
  on another device) but a sync pass can never downgrade an already-locally-read article back to
  unread (`SyncWriter.upsertSummaries`'s upgrade-only rule) — this prevents a racing sync from
  reordering the list under the user's finger. Starring remains a separate, orthogonal
  `Article.starred` boolean with its own "Starred Only" quick-filter, unaffected by read state.
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
  `UpdateAndSync.pollForFreshContent` (bounded-backoff retries of `SyncEngine.sync()`).
  **"Reload"** (the `ArticleListView` swipe, the reader overflow menu) calls
  `ArticleActions.reload(articleServerID:)` (`POST /articles/:id/reload`, that article only) then
  `UpdateAndSync.pollForReloadedContent` (direct re-fetch of `/articles/:id/content` on each poll
  attempt, not through `SyncEngine`'s backfill — see **Actions** above for why). There is no more
  client-side per-feed update/reload or "auto-run a newly created feed" — feed creation/management
  happens entirely in the server's web UI now.
- **SwiftData source of truth, sync writes it:** `SyncEngine`/`SyncWriter` write; views read
  lightweight metadata via `ArticleStore` (backed by SwiftData) rather than per-view `@Query`s.
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
  rework's completion, 289 tests across 77 suites, all passing.
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
  **Still-open, out-of-scope-for-this-plan area:** `MacScreenshotUITests.swift` still selects the
  Settings sidebar pane by the old raw value `"feeds"` (`mac.settings.pane.feeds`), but
  `SettingsPane` (`Yana/Reader/Mac/WindowID.swift`) no longer has a `.feeds` case — the pane set is
  now `general/reader/manage/ai/about`. Mac Catalyst tests aren't part of the iOS Simulator
  `xcodebuild test` run above, so this doesn't show up there.
- Run tests: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- All tests use `@MainActor` for safe concurrency
- **UI-test isolation:** XCTest reuses **one** simulator app container across test classes and runs
  them alphabetically, so `ScreenshotUITests` runs first and seeds a whole fixture library via
  `ScreenshotSeed` — which persists, because that seeder is idempotent and bails once any `Feed`
  exists. Any test asserting on an empty library (or a short Settings form) must therefore pass
  **`-UITEST_RESET_LIBRARY`** (`Yana/Utilities/UITestReset.swift`, DEBUG-only: wipes
  articles/feeds/tags and both timeline anchors at launch, before the seeds run). Without it a test
  passes alone and fails in a full run.
- **Scrolling the Settings form in a UI test:** don't use `app.swipeUp()`. It swipes from the screen
  centre, which lands on control rows and drags a *control value* instead of scrolling, so the form
  stalls and later sections are never reached (an intermittent failure). Use
  `YanaUITests.scrollToSettingsRow(_:in:)`, which drags along the leading edge over the inert row
  labels and waits for `isHittable` rather than `exists`.

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
3. **Endless timeline** — single stream of all articles ordered by import date, swiped both directions, position remembered (device-local)
4. **Tag filter** — filter the timeline by toggling tags (all on by default; includes an "Untagged" entry); tag membership is a live join to the feed's current server-side tags, not a per-article snapshot
5. **Article detail** — render the article's native `[Block]` body (arriving pre-parsed from the server) in the swipe reader
6. **Starred** — star/unstar an article (`Article.starred`, a plain boolean synced via `PATCH /articles/:id`); starred articles are exempt from server-side retention
7. **Update / Reload** — trigger the server's aggregation run (pull-down on the reader, "Update All") or a single article's re-fetch (swipe/reader overflow menu "Reload"), then poll `/articles/sync` or `/articles/:id/content` to pull the result down
8. **Retention** — server-side only; the client mirrors whatever the server decides to keep, receiving deletions through `/articles/sync`'s `removed` list
9. **Background refresh** — best-effort periodic sync via `BGAppRefreshTask`/`BGProcessingTask`
10. **AI summarization** — optional, per-device choice between the server's configured AI provider (`POST /api/v1/ai/prompt`) or on-device Apple Intelligence

### Enhanced
- **Search** ✅ — full-text search across articles (title/plainText/author/feed name) via the reader's `ArticleListView`
- **Feed/tag management** ✅ — moved entirely to the server's own web UI, reached from Settings (`ManagementWebView`) via an embedded WebView that reuses the pairing session's cookies
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
