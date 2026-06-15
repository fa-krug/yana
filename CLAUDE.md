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

- **Models** (`Yana/Models/`): SwiftData `@Model` classes — `Feed`, `FeedGroup`, `Article` —
  plus the typed `AggregatorOptions` enum and the `AppSettings` preferences store.
- **Aggregators** (`Yana/Aggregators/`): the pluggable aggregation system — `AggregatorType`
  (one case per content source), the `Aggregator` protocol, `AggregatedArticle` DTO, and
  `AggregatorRegistry`. Concrete aggregators are added incrementally.
- **Services** (`Yana/Services/`): `AggregationService` (orchestrates feed updates and
  upserts into SwiftData) and `KeychainService` (stores aggregator API keys).
- **Views** (`Yana/Views/`): the swipe-through `ArticleReaderView` (home surface) and the
  configuration hub (feeds, groups, article list, settings).
- **Utilities** (`Yana/Utilities/`): constants and extensions.

### Project structure

- `Yana/YanaApp.swift` — app entry point; creates the SwiftData `ModelContainer`
- `Yana/ContentView.swift` — root view (opens directly into the reader; no auth gate)
- `Yana/Models/AppState.swift` — thin observable UI state (scope, current index, errors)
- `Yana/Utilities/Constants.swift` — app constants

### Key patterns

- **No server:** all content is aggregated on-device. There is no login.
- **SwiftData source of truth:** views read via `@Query`; `AggregationService` writes.
- **Pluggable aggregators:** each content source is an `Aggregator` keyed by `AggregatorType`.
- **Typed options:** per-feed config is a `Codable` `AggregatorOptions` enum, not a JSON blob.
- **Swift 6:** strict concurrency with `@MainActor` annotations throughout.
- **Platform:** iOS 26.0+ (iPhone and iPad).

### Aggregator types

`AggregatorType` mirrors the Yana server's aggregators: `fullWebsite`, `feedContent`
(RSS/Atom), the managed scrapers (`heise`, `merkur`, `tagesschau`, `explosm`, `darkLegacy`,
`caschysBlog`, `mactechnews`, `oglaf`, `meinMmo`), and the social/media sources (`youtube`,
`reddit`, `podcast`). Reddit and YouTube require user-supplied API keys (stored in Keychain).

### Tests
- `YanaTests/` — unit tests using Swift Testing framework (`import Testing`)
- `YanaTests/TestHelper.swift` — shared test utilities
- `YanaUITests/YanaUITests.swift` — UI tests using XCTest
- Run tests: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- All tests use `@MainActor` for safe concurrency

### Translations
- Source language: English (`en`)
- String catalog: `Yana/Resources/Localizable.xcstrings` — Xcode string catalog format (JSON)
- Views use `String(localized:)` for computed property strings and string literals with `LocalizedStringKey` for SwiftUI text
- All user-facing strings should be localizable

## Planned Features

### Core (MVP)
1. **Feed configuration** — create/edit/delete feeds and groups, choose an aggregator type, set per-feed options
2. **Local aggregation** — fetch & parse feeds on-device, store articles in SwiftData
3. **Article list** — list all articles, filter by feed/group and read/unread/starred
4. **Article detail** — render article HTML content in the swipe reader
5. **Read/Unread & Starred** — mark articles read/starred locally
6. **Force update** — update all feeds, a single feed, or a single article on demand
7. **Background refresh** — best-effort periodic aggregation via BGAppRefreshTask
8. **AI post-processing** — optional summarize / improve / translate per feed

### Enhanced
9. **Search** — search across articles
10. **Biometric auth** — Face ID / Touch ID protection (same pattern as MySquad)
11. **Multiple servers** — support connecting to multiple Yana instances
12. **Offline reading** — cache articles locally for offline access
13. **Feed management** — add/remove/rename feeds and groups from the app
14. **Share extension** — share URLs to add as feeds
15. **iPad layout** — multi-column NavigationSplitView for iPad
16. **Widgets** — home screen widgets showing unread counts
17. **Notifications** — push notifications for new articles (if server supports it)
