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
  1440×900pt — 2880×1800 at 2x — suppresses the Mac launch refresh (whose spinner and error toast
  would otherwise land in a frame), and suppresses iCloud sync via a launch argument: the app under
  test shares the real `de.fa-krug.Yana` container, so a developer's synced feeds would otherwise
  appear mid-capture. (SwiftData+CloudKit mirroring is always on but the `-UITEST_MAC_SCREENSHOTS`
  argument disables it for the capture run; no persisted sync preference is modified.)
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

- **Models** (`Yana/Models/`): SwiftData `@Model` classes — `Feed`, `Tag`, `Article`, `StoredImage` —
  plus the typed `AggregatorOptions` enum, `UpdateInterval` (per-device background-refresh schedule),
  and the `AppSettings` preferences store.
- **Aggregators** (`Yana/Aggregators/`): the pluggable aggregation system — `AggregatorType`
  (one case per content source), the `Aggregator` protocol, `AggregatedArticle` DTO,
  `AggregatorRegistry`, and `ArticleSearch` (pure case/diacritic-insensitive matcher over
  title/content/author/feed name). Concrete aggregators are added incrementally.
- **Services** (`Yana/Services/`): `AggregationService` (`@MainActor` coordinator that orchestrates feed updates and delegates the write path to the `@ModelActor` `AggregationWriter` (its own background `ModelContext`), so article upserts, per-feed saves, and retention run off the main thread; `updateAll()`/`update(feed:)` return the count of newly inserted articles; the reader and `ArticleStore` observe committed changes via fresh fetches — the `ModelContext.didSave` observer still fires for the background context's saves, and `ArticleResolution` resolves by a fresh persistent-id-scoped fetch), `KeychainService` (stores aggregator API keys), the AI
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
  background loader, then stays in sync via a coalesced `ModelContext.didSave` observer;
  consumed by both the reader and `ArticleListView` in place of per-view `@Query`s; the reader
  resolves each page's full `Article` (with its `[Block]` body) on demand by `persistentID`) —
  and the **iCloud sync** stack — native SwiftData+CloudKit mirroring, always on.
  `AppContainer.shared` uses `ModelConfiguration(cloudKitDatabase: .automatic)` (the DEBUG
  screenshot/UITest throwaway store stays `.none`). `Feed`, `Tag`, `Article`, and the new
  `StoredImage` `@Model` (`contentHash` + `@Attribute(.externalStorage) data`) mirror to the user's
  private CloudKit database automatically. No opt-in toggle: if the user is not signed into iCloud
  the app silently runs local-only. **CloudKit model invariants — must hold for all future model
  edits:** every attribute optional or defaulted; every relationship optional with an inverse (the
  five to-many relationships `Feed.articles`, `Feed.tags`, `Tag.articles`, `Tag.feeds`,
  `Article.tags` are `[T]?`); no `#Unique`/`@Attribute(.unique)`. `#Index` and `.cascade` delete
  rules are allowed. A DEBUG smoke test `YanaTests/CloudKitSchemaCompatibilityTests` builds an
  on-disk `.automatic` container and asserts it initialises, guarding these invariants. The CloudKit
  schema is auto-derived and created on first write in Development; **it must be deployed to
  Production in the CloudKit Dashboard before release**. To keep the Development schema complete as
  the models evolve, DEBUG builds run **`CloudKitSchemaInitializer`**
  (`Yana/Services/CloudKitSchemaInitializer.swift`) on **every launch**: it builds a temporary
  `NSPersistentCloudKitContainer` over the SwiftData-derived managed object model and calls
  `initializeCloudKitSchema()` (technique: fatbobman.com), pushing the current schema to the
  `iCloud.de.fa-krug.Yana` Development environment (no-op without a signed-in iCloud account; compiled
  out of release builds). **Ordering is load-bearing:** it is invoked *synchronously from the
  `AppContainer.shared` initializer, before the live `.automatic` container is created*, and tears its
  temporary container fully down (`remove(store)`) before returning — a process may host only one
  mirroring container per CloudKit container, so running it concurrently with the live store (e.g.
  from a detached launch `Task`) crashes the app on a signed-in device.
  Images sync via `StoredImage` (mirrored as a CKAsset via `@Attribute(.externalStorage)`).
  `ImageStore` is a disk cache in front of it; `ImageSync` (`Yana/Services/ImageSync.swift`)
  bridges the two — registers `StoredImage` rows after aggregation and materialises blobs on cache
  miss in the reader/logo views.
  Settings sync via `NSUbiquitousKeyValueStore` (`SettingsCloudSync`,
  `Yana/Services/SettingsCloudSync.swift`) for the allow-listed non-secret prefs. API-key secrets
  sync via **iCloud Keychain** — `KeychainService` now writes `kSecAttrSynchronizable` always
  (defaulting true; no toggle). `BackgroundRefreshManager` reschedules itself from the per-device
  **`UpdateInterval`** (`Yana/Models/UpdateInterval.swift`; `AppSettings.updateInterval`): seven
  cases — `off / 30min / 60min / 2h / 4h / 8h / 24h` — stored device-locally and never synced.
  `.off` means no background aggregation and no retention cleanup, but synced articles/deletes still
  arrive; this replaces the old passive-device concept and the formerly synced `backgroundInterval`.
  The Settings Library section shows an `UpdateInterval` Picker; the old iCloud-sync toggle section
  is removed.
  **`LibraryDedup`** (`Yana/Services/LibraryDedup.swift`, `@ModelActor`, run on scene-foreground)
  collapses duplicate `Feed`/`Tag`/`Article` rows (which CloudKit can create since it forbids unique
  constraints) by natural key, keeping the earliest `createdAt` (first-writer-wins) and OR-ing
  starred. **`NativeCloudKitMigration`** (`Yana/Services/NativeCloudKitMigration.swift`, one-time)
  seeds `StoredImage` from the disk cache, forces keys synchronisable, maps old
  `backgroundInterval`/passive → `UpdateInterval`, and pushes prefs to KVS.
  **`LegacyCloudKitCleanup`** (`Yana/Services/LegacyCloudKitCleanup.swift`) performs a best-effort,
  retried deletion of the old `Articles`/`SchemaBootstrap` zones and `ConfigDocument` record.
  `StarredRegistry` (`@MainActor`, `.shared`) still holds lightweight starred identities
  device-locally and re-applies them on a local device re-fetch (`ArticleUpsert`); it is no longer a
  sync mechanism. `ArticleUID` (`Yana/Services/ArticleUID.swift`) remains the canonical article
  identity used for timeline anchor, retention, and dedup.
  **Diagnostics:** `SyncLog` (`Yana/Services/SyncLog.swift`) is a nonisolated, lock-protected
  in-memory ring buffer (2000 entries, current-launch only — no file persistence) that every sync
  path writes to; each entry is also mirrored to `Logger` with `privacy: .public`, because redacting
  those values is exactly the problem this buffer exists to work around — CoreData's own
  `com.apple.coredata` logging blanks the useful ones to `<private>`. **`CloudKitSyncMonitor`**
  (`Yana/Services/CloudKitSyncMonitor.swift`) observes
  `NSPersistentCloudKitContainer.eventChangedNotification` and re-logs the **full** `NSError` tree
  (every `userInfo` key, `CKPartialErrors`, `NSUnderlyingError`, recursively, indented by depth) for
  the same reason. **Ordering is load-bearing:** `start()` is the first statement inside the
  `AppContainer.shared` closure, before the live `.automatic` container is created, because setup
  events — exactly where a container/entitlement/account failure surfaces — fire during
  `ModelContainer.init`, and an observer installed afterwards misses them.
  `SystemLogReader` (`Yana/Services/SystemLogReader.swift`) supplements the buffer with a
  best-effort `OSLogStore(scope: .currentProcessIdentifier)` read of the `com.apple.coredata`
  subsystem — persisted entries only, so it is often empty and can be a complete blackout on a
  locally built Mac Catalyst run. Its `logWindowStart` lower bound is deliberately early — the
  device's boot instant, derived from `ProcessInfo.systemUptime` (time since boot, not time since
  this process launched) rather than a true process-start timestamp — which only widens the fetch
  window and stays safe because `OSLogStore(scope: .currentProcessIdentifier)` already restricts
  results to this process regardless of how far back the query reaches. `SyncDiagnostics`
  (`Yana/Services/SyncDiagnostics.swift`) builds the pinned status header shown above the log —
  iCloud account status, the `iCloud.de.fa-krug.Yana` container, the CloudKit environment derived
  from the build configuration (Debug → Development, release → Production — the two mismatches that
  explain most "sync doesn't work" reports), library row counts, and last import/export/error, the
  last three read from `CloudKitSyncMonitor` (which deliberately never clears the last error on a
  later success, since "sync failed at some point this launch" stays worth knowing even after a
  subsequent export succeeds).
- **Reader** (`Yana/Reader/`): a native SwiftUI body renderer (no WebView). Article bodies are stored as a closed, typed `[Block]` model (`Block.swift`) — paragraphs/headings/lists/blockquotes/images/embeds/code/dividers, with styled `InlineRun`s — produced from the pipeline's sanitized HTML by `BlockParser` at import time, and rendered by `ArticleBlockView` (per-block SwiftUI; `AttributedString` text for selection/Dynamic Type/accessibility; images loaded from the local `ImageStore` by `yana-img://` ref (tapping an image opens it full-screen with pinch-to-zoom, double-tap-to-zoom and swipe-down-to-dismiss via `ReaderImageViewerViewController`); video embeds shown as tappable poster cards and tweet embeds as text cards — tapping a video plays it full-screen in-app via `ReaderVideoPlayerViewController` (YouTube/Dailymotion in a `WKWebView` privacy-mode player; a direct HLS/MP4 stream such as a Reddit `v.redd.it` post in a native `AVPlayerViewController`), while tweets/unplayable embeds open externally). `ReaderHostView`/`ReaderScreen` is the SwiftUI bridge that reads the full lightweight index from `ArticleStore`, remembers scroll position, and hosts the Settings and Filter sheets. It wraps `ReaderArticleViewController` — a `UIPageViewController`-based pager with an opaque native nav bar, a bottom toolbar, and tap-to-hide full-screen mode — whose pages are each a `ReaderBlockViewController` (a `UIHostingController` wrapping `ArticleBlockView`, pull-to-refresh); each page's full `Article` (with blocks) is resolved lazily by `persistentID` when the page is rendered. Body text size is driven by `ArticleTextSize`; links open in `SFSafariViewController` or the system browser (per the "Use System Browser" setting) via `ReaderLinkPolicy`. Read-aloud is handled by `ReaderSpeechController` (AVSpeechSynthesizer; picks the most natural installed voice matching the article's detected language, keeps playing when the screen is locked or the app is backgrounded, and wires up Now Playing / remote play-pause controls). A dedicated **Reader** settings section exposes text size, font, the read-aloud voice, and the system-browser preference. (The former `WKWebView`/warmup/pool/`.nnwtheme`-CSS stack was retired in the native-block migration; `BlockMigration` converts any pre-migration HTML articles to blocks in a one-time background sweep off the launch path.)
- **Views** (`Yana/Views/`): the configuration hub — feeds with OPML import/export, tags, a searchable `ArticleListView` → `ArticleDetailView`, and settings. The Settings screen (`SettingsScreenView`) ends with an **About** section (`aboutSection`) linking the source repo, the issue board (for source/bug requests), and a NetNewsWire credit for the reader view.
  A **Diagnostics** section (iOS, `SettingsScreenView`) and `SettingsPane.diagnostics` (Mac,
  `MacSettingsWindow`) present `SyncLogView` (`Yana/Views/Config/Settings/SyncLogView.swift`) — the
  in-app sync log with a pinned `SyncLogHeaderView` status header, level/source/text filters
  (`SyncLogFilter`), a copy-to-clipboard toolbar action, and a `.txt` `ShareLink`. It ships in every
  build, including release (it is the only way to see why sync fails on a TestFlight/App Store build
  talking to the Production CloudKit environment), but stays hidden until the **About → Version** row
  is tapped five times within three seconds — the pure state machine in `DiagnosticsReveal`
  (`Yana/Views/Config/Settings/DiagnosticsReveal.swift`) drives the gesture so its timing is unit-tested
  without a UI. `AppSettings.diagnosticsUnlocked` (device-local, never synced) persists the reveal
  across launches; a **Hide Diagnostics** action inside the log screen clears it again.
- **Mac Catalyst windowing** (`Yana/Reader/Mac/`): on the Mac idiom, `ContentView` swaps the
  iPhone/iPad full-screen swipe reader for `MacRootView` — a permanent two-column
  `NavigationSplitView` (article-list sidebar + reader detail) — and presents the Welcome
  (onboarding), feed editor, and Settings screens as **separate windows** instead of the
  `.fullScreenCover`/sheets iOS uses. Both the macOS-only `Settings` scene and the singleton
  `Window(id:)` scene are unavailable under Mac Catalyst (it compiles against the iOS SDK), so
  `YanaApp` declares three extra value-based `WindowGroup`s keyed by the stable identifiers in
  `WindowID`, each opened via `openWindow(id:value:)`: `WindowID.settings` and `WindowID.welcome`
  bind `for: Bool.self` and always pass the constant `true` so SwiftUI dedupes to one window
  instead of opening a new one per call; `WindowID.feedEditor` binds `for: FeedEditorTarget.self`
  so every `.create` shares one window and each `.edit(id)` gets its own. `MacSettingsWindow` is a
  two-pane sidebar over `SettingsPane` (General/Reader/Feeds/Tags/Integrations/AI/About — General
  folds in Notifications/Library, which now includes the per-device `UpdateInterval` picker); `WelcomeWindowRoot`/`FeedEditorWindowRoot` host the same
  `WelcomeView`/`FeedEditorView` iOS uses. Each window is its own SwiftUI hierarchy, so they
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
  bounds/clamping handled by `SidebarWidth` (`Yana/Reader/Mac/SidebarWidth.swift`).
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
- `YanaTests/CloudKitSchemaCompatibilityTests.swift` — DEBUG smoke test: builds an on-disk `.automatic` SwiftData container and asserts it initialises, guarding the CloudKit model invariants (all attributes optional/defaulted, relationships optional with inverses, no `#Unique`)
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
- **iCloud sync** ✅ — always-on native SwiftData+CloudKit mirroring of `Feed`, `Tag`, `Article`, and `StoredImage` into the user's private CloudKit database (`iCloud.de.fa-krug.Yana` container, `ModelConfiguration(cloudKitDatabase: .automatic)`). No opt-in toggle: the app runs local-only when the user is not signed into iCloud. Settings (non-secret prefs) sync via `NSUbiquitousKeyValueStore` (`SettingsCloudSync`); API keys sync via iCloud Keychain (always synchronisable). Per-device background-refresh cadence is controlled by `UpdateInterval` (`off / 30min / 1h / 2h / 4h / 8h / 24h`); `.off` acts as a pure-mirror mode (no aggregation, no retention). `LibraryDedup` collapses merge duplicates on scene-foreground. One-time `NativeCloudKitMigration` upgrades existing installs; `LegacyCloudKitCleanup` removes the old hand-built CloudKit zones and records. The CloudKit schema is auto-derived from the SwiftData models — **it must be deployed to Production in the CloudKit Dashboard before release**. A DEBUG smoke test `YanaTests/CloudKitSchemaCompatibilityTests` guards the required model invariants (all attributes optional/defaulted, all relationships optional with inverses, no `#Unique`).
- **Open source** ✅ — MIT-licensed (`LICENSE`); Settings › About links the source repo and issue board, and credits NetNewsWire for the reader view; App Store copy lives under `docs/app-store/`
- **Biometric auth** — Face ID / Touch ID protection (same pattern as MySquad)
- **Multiple libraries** — support multiple independent local feed libraries/profiles
- **Offline reading** — cache articles locally for offline access
- **Share extension** — share URLs to add as feeds
- **iPad layout** — multi-column NavigationSplitView for iPad
- **Widgets** — home screen widgets
