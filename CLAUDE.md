# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Yana iOS is a **native SwiftUI iOS app** that is a fully **self-contained RSS/content
aggregator**. It fetches, parses, and processes feeds on-device and stores everything
locally with SwiftData. There is no server and no network authentication — it mirrors the
aggregation model of the [Yana server](../Yana) but runs entirely on the phone. The app is
designed for privacy-conscious users who want their feeds without any backend.

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
- `fastlane screenshots` — capture + frame the App Store screenshots (en-US, **iPhone-only**,
  6.9″ `iPhone 17 Pro Max`, 1320×2868). Requires `brew install fastlane`.
- Content is a DEBUG-only offline fixture (`ScreenshotSeed`, `Yana/Utilities/ScreenshotSeed.swift`)
  triggered by the `-UITEST_SCREENSHOTS` launch argument that the `ScreenshotUITests` capture flow
  passes — no network, fully reproducible. `ScreenshotSeed` replays a frozen snapshot of REAL feed
  content committed at `Yana/Resources/ScreenshotFixture/manifest.json` (+ `images/<hash>.<ext>`,
  bundled at the app root), originally captured live by `ScreenshotFixtureCollector`
  (`-COLLECT_SCREENSHOT_FIXTURE`) and re-inserted into `ImageStore` at seed time.
- Framing: `fastlane/screenshots/Framefile.json` frames on a solid `background.png` sized to exactly
  1320×2868 (so framed output stays App-Store-valid) with captions from
  `fastlane/screenshots/en-US/title.strings`, rendered in the bundled `OpenSans-Bold.ttf` (SIL OFL —
  frameit resolves the title font relative to the screenshots dir, so a system font can't be used).
- Output (gitignored): `fastlane/screenshots/en-US/*_framed.png`.
- Gotchas: the `screenshots` lane bakes `LANG/LC_ALL=en_US.UTF-8` into the Fastfile because fastlane
  crashes on a bare `C`/US-ASCII shell locale. `ScreenshotSeed` is idempotent (bails if any `Feed`
  exists), so after changing fixture content run `xcrun simctl shutdown all; xcrun simctl erase all`
  before re-capturing, or the stale library persists.

## Architecture

### SwiftUI + SwiftData + local aggregation

- **Models** (`Yana/Models/`): SwiftData `@Model` classes — `Feed`, `Tag`, `Article` —
  plus the typed `AggregatorOptions` enum and the `AppSettings` preferences store.
- **Aggregators** (`Yana/Aggregators/`): the pluggable aggregation system — `AggregatorType`
  (one case per content source), the `Aggregator` protocol, `AggregatedArticle` DTO,
  `AggregatorRegistry`, and `ArticleSearch` (pure case/diacritic-insensitive matcher over
  title/content/author/feed name). Concrete aggregators are added incrementally.
- **Services** (`Yana/Services/`): `AggregationService` (orchestrates feed updates and
  upserts into SwiftData; `updateAll()`/`update(feed:)` return the count of newly inserted
  articles), `KeychainService` (stores aggregator API keys), the AI
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
  reschedules at `AppSettings.backgroundInterval`, runs `updateAll()` in the handler, then posts
  a new-article notification when enabled), `NotificationService` (`Notifying` protocol +
  `NewArticleNotification` gating; opt-in, off by default), and the OPML pair — `OPMLCodec`
  (pure standard-OPML encode/decode with `yana:` extension attributes) and `FeedPortability`
  (`Feed` ↔ OPML mapping: restores type/options/tags, falls back to `feedContent` for foreign
  OPML, dedupes by identifier+type) — and `ArticleStore` (`@MainActor @Observable`; loads the
  whole library's lightweight `ArticleSummary` metadata once at launch via an `@ModelActor`
  background loader, then stays in sync via a coalesced `ModelContext.didSave` observer;
  consumed by both the reader and `ArticleListView` in place of per-view `@Query`s; the reader
  resolves each page's full `Article` (with its `[Block]` body) on demand by `persistentID`).
- **Reader** (`Yana/Reader/`): a native SwiftUI body renderer (no WebView). Article bodies are stored as a closed, typed `[Block]` model (`Block.swift`) — paragraphs/headings/lists/blockquotes/images/embeds/code/dividers, with styled `InlineRun`s — produced from the pipeline's sanitized HTML by `BlockParser` at import time, and rendered by `ArticleBlockView` (per-block SwiftUI; `AttributedString` text for selection/Dynamic Type/accessibility; images loaded from the local `ImageStore` by `yana-img://` ref; video/tweet embeds shown as tappable poster/text cards that open externally). `ReaderHostView`/`ReaderScreen` is the SwiftUI bridge that reads the full lightweight index from `ArticleStore`, remembers scroll position, and hosts the Settings and Filter sheets. It wraps `ReaderArticleViewController` — a `UIPageViewController`-based pager with an opaque native nav bar, a bottom toolbar, and tap-to-hide full-screen mode — whose pages are each a `ReaderBlockViewController` (a `UIHostingController` wrapping `ArticleBlockView`, pull-to-refresh); each page's full `Article` (with blocks) is resolved lazily by `persistentID` when the page is rendered. Body text size is driven by `ArticleTextSize`; links open in `SFSafariViewController` or the system browser (per the "Use System Browser" setting) via `ReaderLinkPolicy`. A dedicated **Reader** settings section exposes text size and the system-browser preference. (The former `WKWebView`/warmup/pool/`.nnwtheme`-CSS stack was retired in the native-block migration; `BlockMigration` converts any pre-migration HTML articles to blocks in a one-time background sweep off the launch path.)
- **Views** (`Yana/Views/`): the configuration hub — feeds with OPML import/export, tags, a searchable `ArticleListView` → `ArticleDetailView`, and settings.
- **Utilities** (`Yana/Utilities/`): constants and extensions.

### Project structure

- `Yana/YanaApp.swift` — app entry point; owns the shared `AppContainer.shared` `ModelContainer`
  and an `AppDelegate` (`UIApplicationDelegateAdaptor`) that bootstraps built-in tags and
  registers/schedules background refresh on launch
- `Yana/ContentView.swift` — root view (opens directly into the reader; no auth gate)
- `Yana/Models/AppState.swift` — thin observable UI state (timeline anchor, tag filter, errors)
- `Yana/Utilities/Constants.swift` — app constants

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
- **SwiftData source of truth:** `AggregationService` writes; views read lightweight metadata via `ArticleStore` (backed by SwiftData) rather than per-view `@Query`s.
- **Pluggable aggregators:** each content source is an `Aggregator` keyed by `AggregatorType`.
- **Typed options:** per-feed config is a `Codable` `AggregatorOptions` enum (one case per
  aggregator type, including per-scraper structs), not a JSON blob.
- **Swift 6:** strict concurrency with `@MainActor` annotations throughout.
- **Platform:** iOS 26.0+ (iPhone and iPad).

### Aggregator types

`AggregatorType` mirrors the Yana server's aggregators: `fullWebsite`, `feedContent`
(RSS/Atom), the managed scrapers (`heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`,
`caschysBlog`, `mactechnews`, `oglaf`, `meinMmo`), and the social/media sources (`youtube`,
`reddit`, `podcast`). Reddit and YouTube require user-supplied API keys (stored in Keychain);
a **Test** button in Settings validates these (and each AI provider key) via a minimal auth probe
before use, with Apple Intelligence checked for on-device availability instead.

### Tests
- `YanaTests/` — unit tests using Swift Testing framework (`import Testing`)
- `YanaTests/TestHelper.swift` — shared test utilities
- `YanaUITests/YanaUITests.swift` — UI tests using XCTest
- Run tests: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- All tests use `@MainActor` for safe concurrency

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
- **Biometric auth** — Face ID / Touch ID protection (same pattern as MySquad)
- **Multiple libraries** — support multiple independent local feed libraries/profiles
- **Offline reading** — cache articles locally for offline access
- **Share extension** — share URLs to add as feeds
- **iPad layout** — multi-column NavigationSplitView for iPad
- **Widgets** — home screen widgets
