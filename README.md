# Yana iOS

A native SwiftUI iOS app that is a fully **self-contained RSS/content aggregator**. It
fetches, parses, and processes feeds **on-device** and stores everything locally with
SwiftData. There is **no server and no login** — it mirrors the aggregation model of the
[Yana server](https://github.com/fa-krug/Yana) but runs entirely on the phone, for
privacy-conscious users who want their feeds without any backend.

## Requirements

- iOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38+

## Setup

1. Install XcodeGen:

   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:

   ```bash
   xcodegen generate
   ```

3. Open the project:

   ```bash
   open Yana.xcodeproj
   ```

4. Select the **Yana** scheme and run on a simulator or device.

## How It Works

- **Add feeds.** In the config hub, create a feed, pick an aggregator type (RSS/Atom, full
  website, a site-specific scraper, Reddit, YouTube, or podcast), set its identifier
  (URL / subreddit / channel) and per-type options, and assign **tags**.
- **Aggregate on-device.** The app fetches and parses each feed locally and stores articles
  in SwiftData. Articles inherit a snapshot of their feed's tags at import time.
- **Read the timeline.** The home surface is a single **endless timeline** of all articles
  ordered by date. Swipe in either direction; the app remembers your position. There is no
  read/unread state.
- **Filter by tags.** A filter button lists every tag (plus "Untagged"), each toggleable —
  all on by default. **Starred** is itself a built-in tag.
- **Refresh.** Pull down on the reader to force-update the current article and the whole
  timeline. Per-feed and all-feeds updates are available in the config hub.
- **Keys.** Reddit and YouTube require user-supplied API keys; AI post-processing
  (summarize / improve / translate) uses your own OpenAI / Anthropic / Gemini / Mistral /
  Qwen / DeepSeek key. Settings shows config fields for the selected provider only (API key,
  model, and — for OpenAI-compatible providers — API URL). A generated summary appears as
  its own block between the article header and body. Secrets are stored in the Keychain.
  A **Test** button in Settings checks each key with a minimal auth call and tells you
  whether it's valid before you rely on it.

## Features

### Core (MVP)
- Feed configuration (create / edit / delete, aggregator type, per-feed options, tags)
- Tag management (create / rename / recolor / delete / reorder; Starred is a locked built-in)
- On-device aggregation into SwiftData
- Endless date-ordered timeline with remembered position
- Tag-based filtering (all on by default; includes "Untagged")
- HTML article rendering in the swipe reader
- Star / unstar; starred articles are exempt from cleanup
- Force update via pull-down; per-feed / all-feeds updates
- ~One-month retention (older non-starred articles are cleaned up)
- Best-effort background refresh
- Optional AI post-processing per feed

### Enhanced (backlog)
- Search across articles
- Biometric authentication (Face ID / Touch ID)
- Offline article caching
- Share extension to add feeds
- iPad multi-column layout
- Home screen widgets
- New-article notifications after a background refresh

## Project Structure

```
Yana/
  YanaApp.swift             # App entry point; creates the SwiftData ModelContainer
  ContentView.swift         # Root view; opens directly into the timeline reader
  Models/                   # SwiftData @Model types (Feed, Tag, Article), options, settings
  Aggregators/              # AggregatorType, Aggregator protocol, registry, DTOs
  Services/                 # AggregationService, KeychainService, AIClient, AIProcessor, CredentialTester
  Views/                    # SwiftUI views (reader + config hub)
  Utilities/                # Constants and extensions
  Resources/                # Asset catalogs, string catalog
  Entitlements/             # iOS entitlements
project.yml                 # XcodeGen project definition
```

## Tests

```bash
# Run unit tests
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- `YanaTests/` — unit tests using the Swift Testing framework (`import Testing`)
- `YanaUITests/` — UI tests using XCTest

## App Store Screenshots

Generate framed, captioned marketing screenshots (English, iPhone-only — 6.9″ `iPhone 17 Pro Max`):

```bash
brew install fastlane   # first time only
fastlane screenshots
```

This runs the `ScreenshotUITests` capture flow against an offline content fixture
(`ScreenshotSeed`, DEBUG-only, gated by the `-UITEST_SCREENSHOTS` launch argument) on the
6.9″ iPhone simulator, then frames the results — device frame + caption on a solid
background sized to exactly 1320×2868 so the output stays App-Store-valid. Captions live in
`fastlane/screenshots/en-US/title.strings`; framed output lands in `fastlane/screenshots/en-US/`.

Notes:
- The `screenshots` lane sets `LANG/LC_ALL=en_US.UTF-8` for you (fastlane crashes on a bare
  `C`/US-ASCII shell locale).
- `ScreenshotSeed` is idempotent (it bails if any feed already exists). After editing the
  fixture content, erase the simulator before re-capturing so it re-seeds fresh:
  `xcrun simctl shutdown all && xcrun simctl erase all`.
- The caption font (`OpenSans-Bold.ttf`, SIL OFL) is bundled under `fastlane/screenshots/`
  because frameit resolves the title font relative to that directory.

## Architecture

- **UI Framework:** SwiftUI (iOS 26.0+)
- **Language:** Swift 6 with strict concurrency (`@MainActor` throughout)
- **Persistence:** SwiftData — the single source of truth for feeds, tags, and articles
- **Aggregation:** pluggable on-device `Aggregator`s keyed by `AggregatorType`, orchestrated
  by `AggregationService`
- **Secrets:** Keychain (Reddit / YouTube / AI provider keys); non-secret prefs in
  `UserDefaults` via `AppSettings`
- **Project Generation:** XcodeGen (`project.yml`)
- **Code Quality:** SwiftLint + SwiftFormat
