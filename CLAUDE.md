# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Yana iOS is a **native SwiftUI iOS app** that is a fully **self-contained RSS/content
aggregator**. It fetches, parses, and processes feeds on-device and stores everything
locally with SwiftData. There is no server and no network authentication — everything runs
entirely on the phone. The app is designed for privacy-conscious users who want their feeds
without any backend. Yana is
open source under the MIT license (`LICENSE`); the source and issue board live at
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
  AI bring-your-own-key section in Settings, reached via `settings.aiSection`). Keep these keys in sync
  across `ScreenshotUITests.swift`, `Framefile.json`'s implied filter, and the `{en-US,de-DE}` caption files.
- Content is a DEBUG-only offline fixture (`ScreenshotSeed`, `Yana/Utilities/ScreenshotSeed.swift`)
  triggered by the `-UITEST_SCREENSHOTS` launch argument that the `ScreenshotUITests` capture flow
  passes — no network, no committed binaries, fully reproducible. `ScreenshotSeed` authors a small
  library of **fully original** invented feeds/articles in-code and generates all imagery in-process:
  `ScreenshotImageFactory` (article lead images) and `ScreenshotLogoFactory` (per-feed logo tiles),
  stored content-addressed via `ImageStore.storeData` so the `yana-img://` refs resolve. Nothing is
  fetched from or copied out of real feeds, so there is no third-party licensing/trademark exposure.
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
  → `02_Search` (sidebar search for "battery") → `03_Feeds` (Settings › Feeds) → `04_AI`
  (Settings › AI). Keep these keys in sync between `MacScreenshotUITests.swift` and `MAC_SHOTS`
  in the Fastfile.
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
  1440×900pt — 2880×1800 at 2x — and suppresses the Mac launch refresh, whose spinner and error
  toast would otherwise land in a frame.
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
  `privacy.html`, `impressum.html`, `terms.html`. Copy is reused from the README and
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

### SwiftUI + SwiftData + local aggregation

- **Models** (`Yana/Models/`): SwiftData `@Model` classes — `Feed`, `Tag`, `Article` — plus the
  typed `AggregatorOptions` enum, `UpdateInterval` (background-refresh schedule), and the
  `AppSettings` preferences store.
- **Aggregators** (`Yana/Aggregators/`): the pluggable aggregation system — `AggregatorType`
  (one case per content source), the `Aggregator` protocol, `AggregatedArticle` DTO,
  `AggregatorRegistry`, and `ArticleSearch` (pure case/diacritic-insensitive matcher over
  title/content/author/feed name). Concrete aggregators are added incrementally.
- **Services** (`Yana/Services/`): `AggregationService` (`@MainActor` coordinator that orchestrates feed updates and delegates the write path to the `@ModelActor` `AggregationWriter` (its own background `ModelContext`), so article upserts, per-feed saves, and retention run off the main thread — every writer call goes through `AggregationService.runOffMain`, which is what actually keeps it there (see **`@ModelActor` runs on its caller's thread** under Key patterns); `updateAll()`/`update(feed:)` return the count of newly inserted articles; the reader and `ArticleStore` observe committed changes via fresh fetches — the `ModelContext.didSave` observer still fires for the background context's saves, and `ArticleResolution` resolves by a fresh persistent-id-scoped fetch), `KeychainService` (stores aggregator API keys), the AI
  post-processing pair — `AIClient` (OpenAI/Anthropic/Gemini/Mistral/Qwen/DeepSeek JSON-mode calls;
  Mistral/Qwen/DeepSeek use the OpenAI-compatible API with a custom `apiBaseURL`) and
  `AIProcessor` (gate, HTML strip, prompt, drop-on-failure; runs after the run cap, before upsert;
  when summarization is enabled a `summary` field is stored on the article and rendered as its own
  block between the lead image and the article text in the reader) —
  `CredentialTester` (validates entered Reddit/YouTube/AI keys via a minimal auth probe on each
  client — `RedditClient.verifyCredentials`, `YouTubeClient.verifyKey`, `AIClient.verify` — mapping
  outcomes to a shared `CredentialTestError`: invalid-credentials / network / unexpected-response;
  surfaced by per-section **Test** buttons in Settings; the AI section shows config fields — API key,
  model, and (for OpenAI-compatible providers) API URL — for the selected provider only) —
  `BackgroundRefreshManager` (best-effort periodic `BGAppRefreshTask`: registers at launch,
  reschedules from the per-device `AppSettings.updateInterval` (`UpdateInterval` enum), runs
  `updateAll()` in the handler unless `.off`, then posts a new-article notification when enabled), `NotificationService` (`Notifying` protocol +
  `NewArticleNotification` gating; opt-in, off by default), and the OPML pair — `OPMLCodec`
  (pure standard-OPML encode/decode with `yana:` extension attributes) and `FeedPortability`
  (`Feed` ↔ OPML mapping: restores type/options/tags, falls back to `feedContent` for foreign
  OPML, dedupes by identifier+type) — and `ArticleStore` (`@MainActor @Observable`; loads the
  whole library's lightweight `ArticleSummary` metadata once at launch via an `@ModelActor`
  loader wrapped in `OffMainActor.run` (the wrapper, not the `@ModelActor`, is what puts the fetch
  on a background thread), then keeps it current **incrementally**: `ModelContext.didSave` carries
  the `PersistentIdentifier`s of the rows a save touched, so `LibraryChangeSet` filters them to
  `Article`s and `SummaryIndexMerge` splices just those rows into the `createdAt`-ascending index —
  work proportional to the change, not to the library. A save touching no `Article` (a feed logo, a
  tag) costs nothing at all, and a burst is coalesced and single-flighted.
  Falls back to a full re-read when the change set exceeds `spliceLimit`, or when the index came
  from the disk cache and so carries no `persistentID`s to match on (`SummaryIndexMerge.isSpliceable`).
  The store is local-only, so `ModelContext.didSave` is the single trigger — every write goes
  through a SwiftData context and therefore names its rows.
  The disk cache is rewritten on a `cacheWriteDelay` timer, not per refresh, and flushed on
  scene-background;
  consumed by both the reader and `ArticleListView` in place of per-view `@Query`s; the reader
  resolves each page's full `Article` (with its `[Block]` body) on demand by `persistentID`) —
  and `StarredRegistry` (`@MainActor`, `.shared`; holds lightweight starred identities so a local
  re-fetch can re-apply them in `ArticleUpsert`).
  `ArticleUID` (`Yana/Services/ArticleUID.swift`) is the canonical article identity used by the
  timeline anchor, retention, and dedup; it is length-bounded (over 255 UTF-16 units collapses to a
  `sha256:` digest) so it can never be unbounded.
  **`TimelineAnchorWriter`** (`Yana/Services/TimelineAnchorWriter.swift`) is the single write path
  both platforms' user-driven selection changes go through, persisting both
  `AppSettings.timelineAnchorIdentifier` and the canonical `timelineAnchorSyncUID`. On iOS,
  **`ReaderAnchorController`** (`Yana/Reader/ReaderAnchorController.swift`) wraps it and is
  `ReaderHostView`'s whole timeline-anchor read/write surface (`saveAnchor`/`openArticle` call
  `record`/`recordOpenedArticle`); a SwiftUI view struct has no test harness in this codebase, so
  this extraction is what makes the behaviour assertable at all. On Mac, `TimelineModel` holds the
  writer directly (`anchorWriter`) from its `selection` setter / `moveSelection`. The read-side
  reanchor (`ReaderAnchorController.reanchorIndex`, `TimelineModel.reanchorToCurrentArticle`, run on
  every timeline delivery once the anchor has been restored) prefers the UID over the identifier
  before falling back — the UID also carries the feed, so it still resolves after a re-import that
  changed the article's row identity.
  **`LegacySettingsMigration`** (`Yana/Services/LegacySettingsMigration.swift`, one-time, run from
  the scene task) is the upgrade path off the removed iCloud-sync build: it re-saves API keys out of
  the iCloud-synchronizable keychain domain into a device-local one, and maps the pre-`UpdateInterval`
  `backgroundInterval`/passive-device defaults onto `AppSettings.updateInterval`.
  `BackgroundRefreshManager` reschedules itself from **`UpdateInterval`**
  (`Yana/Models/UpdateInterval.swift`; `AppSettings.updateInterval`): seven cases —
  `off / 30min / 60min / 2h / 4h / 8h / 24h`. `.off` means no background aggregation and no
  retention cleanup. The Settings Library section shows an `UpdateInterval` Picker.
  **There is no sync of any kind, and no network destination the app writes to** — the SwiftData
  store is a plain local `ModelConfiguration()`, API keys are written non-synchronizable, and the
  app declares no iCloud/CloudKit entitlement. Keep it that way: adding one back means re-deriving a
  CloudKit schema and re-imposing the model invariants (all attributes optional/defaulted, all
  relationships optional with inverses, no `#Unique`) that were dropped with it.
- **Mac Catalyst windowing** (`Yana/Reader/Mac/`): on the Mac idiom, `ContentView` swaps the
  iPhone/iPad full-screen swipe reader for `MacRootView` — a permanent two-column
  `NavigationSplitView` (article-list sidebar + reader detail) — and presents the Welcome
  (onboarding) and Settings screens as **separate windows** instead of the
  `.fullScreenCover`/sheets iOS uses. Both the macOS-only `Settings` scene and the singleton
  `Window(id:)` scene are unavailable under Mac Catalyst (it compiles against the iOS SDK), so
  `YanaApp` declares two extra value-based `WindowGroup`s keyed by the stable identifiers in
  `WindowID`, each opened via `openWindow(id:value:)`: `WindowID.settings` and `WindowID.welcome`
  bind `for: Bool.self` and always pass the constant `true` so SwiftUI dedupes to one window
  instead of opening a new one per call. The **feed editor is deliberately not a window**: editing a
  feed pushes in place inside the Settings window's `NavigationStack` (like the Tags pane) and
  creating one presents a sheet (like Add Tag), so `FeedsView` now takes the same path on both
  platforms and `WindowID.feedEditor`/`FeedEditorTarget`/`FeedEditorWindowRoot` are gone.
  `MacSettingsWindow` is a
  two-pane sidebar over `SettingsPane` (General/Reader/Feeds/Tags/Integrations/AI/About — General
  folds in Notifications/Library, which now includes the per-device `UpdateInterval` picker);
  `WelcomeWindowRoot` hosts the same
  `WelcomeView` iOS uses. Each window is its own SwiftUI hierarchy, so they
  coordinate through shared observable state (`AppState`, `ArticleStore`, `AppSettings`) passed in
  at scene creation rather than closures back to a presenting view. `MacCommands.swift` adds the
  Mac menu-bar commands (article navigation, star, read-aloud, update-all), reading the frontmost
  window's `TimelineModel`/`ReaderSpeechController` via `FocusedValues` that `MacRootView` publishes.
  Sidebar rows (`MacArticleRow`) expose a right-click **context menu** (Star/Unstar, Open in Browser,
  Copy Link, Reload, and Summarize when AI is configured) and a hover highlight on unselected rows.
  The window uses a Mail-style two-pane keyboard focus model (`MacFocusPane`): Return moves focus from
  the sidebar into the reader, Esc returns it to the sidebar; the same article actions (Open in Browser,
  Copy Link, Reload) are also surfaced in the Article menu for discoverability. The sidebar width is
  remembered across launches via `AppSettings.macSidebarWidth` (device-local, never synced), with
  bounds/clamping handled by `SidebarWidth` (`Yana/Reader/Mac/SidebarWidth.swift`). The sidebar also
  scrolls to follow a **programmatic** selection change: `TimelineModel` bumps a `scrollTarget`
  (`SidebarScrollRequest { id, token }`) from `moveSelection`, the launch anchor restore, a remote
  anchor landing via `jumpToSyncedTimelinePosition`, and the `reanchorToCurrentArticle` self-heal —
  never from the `selection` setter the `List` itself drives on a user click, which would fight the
  user's own scrolling. `MacSidebarView` consumes it via `.scrollPosition(id:anchor:)` applied
  directly to the `List` (not a wrapping `ScrollViewReader`, which previously suppressed the
  source-list chrome — translucent material, inset rounded selection, no separators — and was
  removed for exactly that reason); `token` always increments even when `id` repeats, so a second
  request for the same article isn't silently deduped by SwiftUI's value-equality change detection.
  `displayed` (the rows actually shown — `model.filteredArticles`, or live search results re-run
  through the tag/feed filter) is cached in `@State` rather than computed, because
  `.scrollPosition(id:)` is a two-way binding that SwiftUI writes back on every row-crossing-centre
  event while the user scrolls, and a computed `displayed` re-ran both filter passes on every one of
  those scroll-driven `body` re-evaluations.
  **Mac chrome conventions** live in two no-op-off-Catalyst helpers so every "this only looks wrong
  on the Mac" tweak has one home: `MacToolbarStyle.swift` (`macToolbarIcon()` — horizontal label
  padding, without which a lone toolbar button's background is an upright oval reading as a "0"; peer
  actions go in **one `ControlGroup` hosted directly by a `ToolbarItem`**, which is the only
  construction Catalyst actually joins — a `ToolbarItemGroup` renders separate round buttons and a
  `ControlGroup` *nested* in one renders blank — and a pull-down `Menu` stays its own item with
  `.menuIndicator(.hidden)`) and `MacFormStyle.swift` (`macDisclosureLabel()` — the Mac idiom draws a
  `DisclosureGroup`'s chevron on the leading edge with no gap). `.toggleStyle(.switch)` must be set
  per window, since each is its own SwiftUI hierarchy. The sidebar's selection fill is the accent
  damped toward black (`MacSidebarView.selectionTint`), and `MacArticleRow` inverts its
  accent-tinted feed name to white on the selected row so it does not vanish into that fill.
- **Utilities** (`Yana/Utilities/`): constants and extensions.

### Project structure

- `Yana/YanaApp.swift` — app entry point; owns the shared `AppContainer.shared` `ModelContainer`
  and an `AppDelegate` (`UIApplicationDelegateAdaptor`) that bootstraps built-in tags and
  registers/schedules background refresh on launch
- `Yana/ContentView.swift` — root view (opens directly into the reader; no auth gate). On first
  launch it presents `WelcomeView` (`Yana/Views/WelcomeView.swift`) as a full-screen onboarding
  cover, gated by the one-time `AppSettings.hasCompletedOnboarding` flag (skipped under the
  `-UITEST_SKIP_ONBOARDING` / `-UITEST_SCREENSHOTS` launch arguments). `WelcomeView` is a paged
  coordinator over three steps — welcome/feature highlights, optional AI-provider setup (reuses
  `CredentialTester`/`KeychainService`/`AppSettings.aiModel(for:)`; basics only, no advanced knobs),
  and a first feed (reuses `FeedEditorView`'s auto-fetch `onCreate` path and `FeedPortability.importOPML`)
- `Yana/Models/AppState.swift` — thin observable UI state (timeline anchor, tag filter, errors)
- `Yana/Utilities/Constants.swift` — app constants
- `LICENSE` — MIT license
- `docs/app-store/` — App Store listing copy: English + German descriptions (`description-*.md`, ≤4000 chars each) and keyword lines (`keywords-*.txt`, ≤100 chars each), plus a `README.md` documenting the field format
- `docs/site/` — the GitHub Pages marketing + legal site (`index.html` + `privacy`/`impressum`/`terms`, `assets/`), deployed to `yana.fa-krug.de` by `.github/workflows/pages.yml` (see **Website** under Commands)

### Key patterns

- **No server:** all content is aggregated on-device. There is no login.
- **No read/unread state:** the home surface is a single **endless timeline** of all articles
  ordered by import date (`Article.createdAt`), swiped both directions, with the position remembered
  across launches. The full lightweight index is loaded upfront from `ArticleStore` and kept in sync
  with SwiftData saves; the reader decodes each page's `[Block]` body lazily. Re-fetched articles keep their
  original `createdAt`, so updates don't jump the timeline. Newly imported articles get their
  `createdAt` back-dated by a small random offset (`ArticleUpsert.importJitterWindow`) so a run's
  inserts scatter across a few minutes and feeds interleave instead of clustering into per-feed blocks.
- **Tags, not groups:** feeds carry tags, which are **snapshotted onto each article at import
  time** (not retroactive). **Starred is a built-in tag** applied per-article. The timeline is
  filtered by toggling tags (all on by default; an "Untagged" entry covers tagless articles).
- **Update vs. reload:** two distinct semantics, reflected in the action labels. **"Update"**
  fetches only **new** articles (intake-window filtered, daily cap applied): the reader's
  **pull-down gesture** and the Feeds screen's **"Update all"** call `AggregationService.updateAll()`
  (all enabled feeds); the Feeds swipe **"Update"** calls `update(feed:)` (that feed only).
  **"Reload"** completely re-fetches in place, bypassing the intake window/cap and upserting
  (content refreshed; `createdAt` + Starred preserved): the reader overflow menu's **"Reload"** and
  the `ArticleListView` swipe's **"Reload"** call `forceReload(article:)` (current article only —
  every aggregator now re-fetches a single item: website/scrapers re-scrape the page, RSS/podcast pick the matching feed entry, YouTube/Reddit fetch the one video/post; if the item is gone it leaves the article untouched and never reloads the feed), while the Feeds
  swipe **"Reload"** calls `forceReload(feed:)` (re-imports everything the feed offers).
- **Auto-run new feeds:** creating a feed in `FeedEditorView` immediately fetches it — after
  the insert, `save()` calls an `onCreate` callback that `FeedsView` wires to `update(feed:)`
  (same path as the swipe "Update"), so a new enabled feed's articles appear without a manual
  update. Feeds created disabled are skipped.
- **SwiftData source of truth:** `AggregationService` writes; views read lightweight metadata via `ArticleStore` (backed by SwiftData) rather than per-view `@Query`s.
- **Pluggable aggregators:** each content source is an `Aggregator` keyed by `AggregatorType`.
- **Typed options:** per-feed config is a `Codable` `AggregatorOptions` enum (one case per
  aggregator type, including per-scraper structs), not a JSON blob.
- **Swift 6:** strict concurrency with `@MainActor` annotations throughout.
- **`@ModelActor` runs on its caller's thread — always wrap it in `OffMainActor.run`.** A
  `@ModelActor` does **not** own a background queue: SwiftData's `DefaultSerialModelExecutor` runs
  enqueued jobs inline on the calling thread, so `await someModelActor.work()` from a `@MainActor`
  type performs the whole fetch/save **on the main thread**. Constructing the actor off-main does not
  help — the thread is chosen at the `await`, not at `init`. Declaring a type `@ModelActor` therefore
  says nothing about which thread it runs on; only the caller does. This is the single biggest
  main-thread hazard in this codebase: it turned a large import (a burst of saves, each waking
  `ArticleStore`'s full re-index) into a ~300 ms UI freeze per batch on a 4 000-article library.
  Every main-actor → `@ModelActor` call must go through `OffMainActor.run`
  (`Yana/Utilities/OffMainActor.swift`): `ArticleStore.fullLoad`/`publishFastDataset` and
  `AggregationService.runOffMain` (all five `AggregationWriter` entry points). `OffMainActorTests`
  pins the executor behaviour (including the "created off-main is not enough" case) so a future
  SwiftData change is caught, and `SyncReactionMainThreadTests` measures main-actor responsiveness
  across the whole import-reaction chain — a regression there shows up as a stall, not a wrong value.
- **Platform:** iOS 26.0+ (iPhone and iPad).

### Aggregator types

`AggregatorType` covers these aggregators: `fullWebsite`, `feedContent`
(RSS/Atom), the managed scrapers (`heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`,
`caschysBlog`, `mactechnews`, `oglaf`, `meinMmo`, `theVerge`, `arsTechnica`), and the social/media sources (`youtube`,
`reddit`, `podcast`). Reddit and YouTube require user-supplied API keys (stored in Keychain);
a **Test** button in Settings validates these (and each AI provider key) via a minimal auth probe
before use, with Apple Intelligence checked for on-device availability instead.

### Tests
- `YanaTests/` — unit tests using Swift Testing framework (`import Testing`)
- `YanaTests/TestHelper.swift` — shared test utilities
- `YanaTests/LegacySettingsMigrationTests.swift` — pins the one-time upgrade off the removed
  iCloud-sync build: the legacy passive-device flag and `backgroundInterval` map onto
  `UpdateInterval`, and a second run never re-applies them over a choice the user has since changed.
- `YanaTests/ReaderAnchorControllerTests.swift`/`TimelineModelTests.swift`/
  `TimelineAnchorWriterTests.swift` — pin the timeline-anchor read/write split on both platforms:
  which paths persist a new anchor, and that the read-side reanchor prefers the canonical UID.
- `YanaUITests/YanaUITests.swift` — UI tests using XCTest
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
  centre, which lands on the AI section's slider/stepper rows and drags a *control value* instead of
  scrolling, so the form stalls and the About section is never reached (an intermittent failure).
  Use `YanaUITests.scrollToSettingsRow(_:in:)`, which drags along the leading edge over the inert row
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
1. **Feed configuration** — create/edit/delete feeds, choose an aggregator type, set per-feed options, assign tags
2. **Tag management** — create/rename/recolor/delete/reorder tags; Starred is a locked built-in tag
3. **Local aggregation** — fetch & parse feeds on-device, store articles in SwiftData (tags snapshotted per article at import)
4. **Endless timeline** — single stream of all articles ordered by import date, swiped both directions, position remembered
5. **Tag filter** — filter the timeline by toggling tags (all on by default; includes an "Untagged" entry)
6. **Article detail** — render the article's native `[Block]` body in the swipe reader
7. **Starred** — star/unstar an article (adds/removes the built-in Starred tag); starred articles are exempt from cleanup
8. **Force update** — pull-down on the reader (current article + whole timeline); per-feed / all-feeds from the config hub
9. **Retention** — keep ~one month of articles; delete older ones (except Starred)
10. **Background refresh** — best-effort periodic aggregation via BGAppRefreshTask
11. **AI post-processing** — optional summarize / improve / translate per feed

### Enhanced
- **Search** ✅ — search across articles (title/content/author/feed name) via the config hub's `ArticleListView`
- **OPML import/export** ✅ — standard OPML with `yana:` extension attributes for full-fidelity round-trip, from the Feeds screen
- **Notifications** ✅ — opt-in (off by default) local notification with the new-article count after a background refresh
- **Credential validation** ✅ — per-section **Test** buttons in Settings that verify Reddit, YouTube, and AI-provider keys (and Apple Intelligence availability) via a minimal auth probe, classifying failures as invalid credentials / network / unexpected response
- **Read-aloud** ✅ — `ReaderSpeechController` reads articles aloud with a voice matching the article's language, continues from the lock screen / Control Center, and exposes a voice picker in the Reader settings section
- **Local-only by design** ✅ — the library lives in a plain local SwiftData store (`ModelConfiguration()`), API keys are written to the keychain non-synchronizable, and the app declares no iCloud/CloudKit entitlement. An earlier build shipped SwiftData+CloudKit mirroring; it was removed, and `LegacySettingsMigration` is the one-time upgrade path off it (keys back to device-local, legacy `backgroundInterval`/passive flag mapped onto `UpdateInterval`). Background-refresh cadence is `UpdateInterval` (`off / 30min / 1h / 2h / 4h / 8h / 24h`); `.off` disables background aggregation and retention cleanup.
- **Open source** ✅ — MIT-licensed (`LICENSE`); Settings › About links the source repo and issue board, and credits NetNewsWire for the reader view; App Store copy lives under `docs/app-store/`
- **Biometric auth** — Face ID / Touch ID protection (same pattern as MySquad)
- **Multiple libraries** — support multiple independent local feed libraries/profiles
- **Offline reading** — cache articles locally for offline access
- **Share extension** — share URLs to add as feeds
- **iPad layout** — multi-column NavigationSplitView for iPad
- **Widgets** — home screen widgets
