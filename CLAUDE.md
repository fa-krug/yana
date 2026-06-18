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
  OPML, dedupes by identifier+type).
- **Reader** (`Yana/Reader/`): a UIKit port of NetNewsWire's reader. `ReaderHostView`/`ReaderScreen` is the SwiftUI bridge that owns the `@Query` timeline, remembers scroll position, and hosts the Settings and Filter sheets. It wraps `ReaderArticleViewController` — a `UIPageViewController`-based pager with an opaque native nav bar, a bottom toolbar, and tap-to-hide full-screen mode — whose pages are each a `ReaderWebViewController` (per-article `WKWebView`, pull-to-refresh, native-browser links). Article HTML is rendered by `ArticleRenderer` + `MacroProcessor` driving NNW's `.nnwtheme` themes via `ArticleThemesManager` (8 bundled themes under `Yana/Resources/Themes/`, with CSS/templates under `Yana/Resources/ArticleRendering/`) and `ArticleTextSize`. Links open in `SFSafariViewController` or the system browser when the "Use System Browser" setting is on. A dedicated **Reader** settings section exposes theme, text size, and system-browser preference.
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
  across launches. Re-fetched articles keep their original `createdAt`, so updates don't jump the
  timeline.
- **Tags, not groups:** feeds carry tags, which are **snapshotted onto each article at import
  time** (not retroactive). **Starred is a built-in tag** applied per-article. The timeline is
  filtered by toggling tags (all on by default; an "Untagged" entry covers tagless articles).
- **Force update:** a **pull-down gesture** on the reader (now the ported `ReaderWebViewController`) refreshes the current article and the whole timeline; per-feed / all-feeds updates also live in the config hub.
- **SwiftData source of truth:** views read via `@Query`; `AggregationService` writes.
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
6. **Article detail** — render article HTML content in the swipe reader
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
