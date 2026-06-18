# Contributing to Yana iOS

## Prerequisites

- iOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38+

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

## On-Device Aggregation

There is **no server and no login.** The app fetches, parses, and processes every feed
on-device and stores articles locally with SwiftData. Each content source is a pluggable
`Aggregator` keyed by an `AggregatorType`, orchestrated by `AggregationService`. Reddit and
YouTube use user-supplied API keys (stored in the Keychain); AI post-processing uses your own
OpenAI / Anthropic / Gemini key. See [CLAUDE.md](CLAUDE.md) for the full architecture.
