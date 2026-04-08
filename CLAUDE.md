# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Yana iOS is a **native SwiftUI iOS app** that serves as a mobile client for the [Yana RSS aggregator](../Yana). It communicates with a self-hosted Yana server via the **Google Reader API** to display feeds, articles, and manage read/starred state. The app is designed for privacy-conscious users who run their own Yana instance.

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

### SwiftUI + Google Reader API
- **Views** (`Yana/Views/`): SwiftUI views organized by feature area. Uses `TabView` with tab sections for main navigation.
- **Models** (`Yana/Models/`): Data models — both local state (`AppState`) and API response models for the Google Reader protocol.
- **Services** (`Yana/Services/`): Business logic — API client, authentication, keychain, background sync.
- **Utilities** (`Yana/Utilities/`): Constants (API paths, bundle IDs) and extensions.

### Project structure
- `Yana/YanaApp.swift` — app entry point, defines root scene
- `Yana/ContentView.swift` — root view with auth gating (login vs main app)
- `Yana/Models/AppState.swift` — observable app state (auth status, server URL, token)
- `Yana/Utilities/Constants.swift` — app constants (bundle ID, all Google Reader API paths and tag constants)
- `Yana/Entitlements/Yana-iOS.entitlements` — iOS entitlements (keychain access)
- `Yana/Resources/Assets.xcassets` — asset catalog (app icon, accent color)
- `Yana/Resources/Localizable.xcstrings` — string catalog for localization
- `Yana/Resources/PrivacyInfo.xcprivacy` — privacy manifest
- `project.yml` — XcodeGen project definition (iOS target)

### Key patterns
- **Auth flow**: App starts with login screen → user enters server URL + credentials → authenticates via Google Reader ClientLogin API → stores token in Keychain → shows main feed view
- **Google Reader API**: All server communication uses the GReader-compatible API exposed by the Yana Django backend. Endpoints are defined in `Constants.swift`
- **No local database**: Articles are fetched from the server on demand. Local caching may be added later.
- **Swift 6**: Strict concurrency with `@MainActor` annotations throughout
- **Platform**: iOS 26.0+ (iPhone and iPad)

### Yana Server API Reference

The app communicates with a Yana server instance via these Google Reader API endpoints:

**Authentication:**
- `POST /api/greader/accounts/ClientLogin` — email + password → returns auth token
- `GET /api/greader/reader/api/0/token` — get action token for write operations
- `GET /api/greader/reader/api/0/user-info` — get authenticated user info

**Feeds & Groups:**
- `GET /api/greader/reader/api/0/subscription/list` — list all feeds with metadata
- `POST /api/greader/reader/api/0/subscription/edit` — add/remove/rename feeds
- `POST /api/greader/reader/api/0/subscription/quickadd` — quick-add feed by URL
- `GET /api/greader/reader/api/0/tag/list` — list all feed groups/labels

**Articles:**
- `GET /api/greader/reader/api/0/unread-count` — unread counts per feed
- `GET /api/greader/reader/api/0/stream/items/ids` — get article IDs (paginated)
- `POST /api/greader/reader/api/0/stream/items/contents` — get full article content
- `POST /api/greader/reader/api/0/edit-tag` — mark articles read/starred
- `POST /api/greader/reader/api/0/mark-all-as-read` — mark entire feed as read

**Auth header:** `Authorization: GoogleLogin auth=<TOKEN>`

**ID formats:**
- Stream ID: `feed/{id}`, `user/-/label/{name}`, `user/-/state/com.google/starred`
- Item ID: `tag:google.com,2005:reader/item/{16-hex-digits}`

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
1. **Server connection** — configure server URL, authenticate with email/password
2. **Feed list** — show all subscriptions grouped by label/folder
3. **Article list** — show articles for a feed or group, with unread counts
4. **Article detail** — render article HTML content in a reader view
5. **Read/Unread** — mark articles as read, mark all as read
6. **Starred articles** — star/unstar articles, view starred list
7. **Pull-to-refresh** — refresh feed content from server
8. **Background refresh** — periodic background fetch of new articles

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
