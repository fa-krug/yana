# Contributing to Yana iOS

## Prerequisites

- iOS 26.0+ / macOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38+

## Getting Started

```bash
# Clone the repo
git clone <repo-url> && cd yana

# Install XcodeGen
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open Yana.xcodeproj
```

There are two schemes: **Yana** for iOS/iPadOS and **Yana-macOS** for the native Mac app.
Select the one for the platform you're working on and press Cmd+R. The Mac app is its own
target, not a Catalyst variant of the iOS one, so the **Yana** scheme cannot be built for a Mac
destination.

## Project Structure

```
Yana/                       # All Swift source code
  YanaApp.swift             # App entry point
  ContentView.swift         # Root view
  Models/                   # SwiftData @Model types (Feed, Tag, Article), options, settings
  Aggregators/              # AggregatorType, Aggregator protocol, registry, DTOs
  Views/                    # SwiftUI views by feature
  Services/                 # On-device aggregation, Keychain, AI, credential validation
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

# macOS
xcodebuild -scheme Yana-macOS -destination 'platform=macOS' build

# Run the iOS tests
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run the macOS unit tests
xcodebuild -scheme Yana-macOS -destination 'platform=macOS' -only-testing:YanaTests-macOS test
```

Archiving the Mac app uses `-scheme Yana-macOS -destination 'generic/platform=macOS'`. There is
no `variant=Mac Catalyst` destination on any scheme any more.

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
# Run all unit tests (iOS)
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run all unit tests (macOS)
xcodebuild -scheme Yana-macOS -destination 'platform=macOS' -only-testing:YanaTests-macOS test
```

Both test targets build from the same `YanaTests/` directory; platform differences are gated in
the source with `#if`. `-only-testing:YanaTests-macOS` matters on the Mac, because the macOS UI
tests need an interactive desktop session and can't run from a non-interactive shell.

## On-Device Aggregation

There is **no server and no login.** The app fetches, parses, and processes every feed
on-device and stores articles locally with SwiftData. Each content source is a pluggable
`Aggregator` keyed by an `AggregatorType`, orchestrated by `AggregationService`. Reddit and
YouTube use user-supplied API keys (stored in the Keychain); AI post-processing uses your own
OpenAI / Anthropic / Gemini key. See [CLAUDE.md](CLAUDE.md) for the full architecture.
