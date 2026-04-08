# Contributing to Yana iOS

## Prerequisites

- iOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38+
- A running [Yana](../Yana) server instance for testing

## Getting Started

```bash
# Clone the repo
git clone <repo-url> && cd yana-ios

# Install XcodeGen
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open Yana.xcodeproj
```

Select the **Yana** scheme and press Cmd+R to build and run.

## Project Structure

```
Yana/                       # All Swift source code
  YanaApp.swift             # App entry point
  ContentView.swift         # Root view
  Models/                   # Data models (AppState, API types)
  Views/                    # SwiftUI views by feature
  Services/                 # Business logic (API, auth, sync)
  Utilities/                # Constants and extensions
  Resources/                # Asset catalogs
  Entitlements/             # iOS entitlements
project.yml                 # XcodeGen project definition
```

## XcodeGen

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj` from `project.yml`. This avoids merge conflicts in Xcode project files.

**After adding or removing source files**, re-run:

```bash
xcodegen generate
```

The generated `Yana.xcodeproj` is gitignored — every developer generates it locally.

## Building from the Command Line

```bash
# iOS Simulator
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run tests
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Code Style

- Follow standard Swift conventions and SwiftUI patterns
- Use `@Observable` for services and state objects
- All new user-facing strings must be localizable
- Use `String(localized:)` when the string is in a computed property or non-View context
- SwiftUI `Text("...")` literals use `LocalizedStringKey` automatically

## Tests

Unit tests use the **Swift Testing** framework (`import Testing`, not XCTest). All tests run with `@MainActor`.

```
YanaTests/
  TestHelper.swift            # Shared test utilities
  YanaTests.swift             # Unit tests
YanaUITests/
  YanaUITests.swift           # UI tests (XCTest)
```

```bash
# Run all unit tests
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Server API

The app communicates with a Yana server via the Google Reader-compatible API. Key endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/greader/accounts/ClientLogin` | POST | Authenticate |
| `/api/greader/reader/api/0/subscription/list` | GET | List feeds |
| `/api/greader/reader/api/0/unread-count` | GET | Unread counts |
| `/api/greader/reader/api/0/stream/items/ids` | GET | Article IDs |
| `/api/greader/reader/api/0/stream/items/contents` | POST | Article content |
| `/api/greader/reader/api/0/edit-tag` | POST | Mark read/starred |

Auth header: `Authorization: GoogleLogin auth=<TOKEN>`

See the [Yana CLAUDE.md](../Yana/CLAUDE.md) for full API documentation.
