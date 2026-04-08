# Yana iOS

A native iOS client for [Yana](../Yana), a self-hosted RSS aggregator. Built with SwiftUI, communicates with the Yana server via the Google Reader-compatible API.

## Requirements

- iOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38+
- A running [Yana](../Yana) server instance

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

## Connecting to Your Server

1. Launch the app
2. Enter your Yana server URL (e.g., `http://192.168.1.100:8000`)
3. Sign in with your Yana admin credentials
4. Your feeds and articles will sync automatically

## Features

### Planned (MVP)
- Server connection with Google Reader API authentication
- Feed list with unread counts, organized by groups/labels
- Article list with pull-to-refresh
- Article detail view with HTML rendering
- Mark read/unread, star/unstar articles
- Mark all as read
- Background refresh

### Planned (Enhanced)
- Biometric authentication (Face ID / Touch ID)
- Offline article caching
- Feed management (add/remove/rename)
- Search across articles
- iPad multi-column layout
- Multiple server support
- Share extension
- Home screen widgets

## Project Structure

```
Yana/
  YanaApp.swift             # App entry point
  ContentView.swift         # Root view with auth gating
  Models/                   # Data models (AppState, API response types)
  Views/                    # SwiftUI views by feature
  Services/                 # Business logic (API client, auth, sync)
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

## Yana Server

This app requires a running Yana server. See the [Yana project](../Yana) for setup instructions. The quickest way:

```bash
docker-compose up -d
# Access admin at http://localhost:8000/admin
# API at http://localhost:8000/api/greader/
```

## Architecture

- **UI Framework:** SwiftUI (iOS 26.0+)
- **Language:** Swift 6 with strict concurrency
- **API Protocol:** Google Reader API (GReader-compatible)
- **Auth:** Google Reader ClientLogin (email/password -> token)
- **Storage:** Keychain for auth tokens
- **Project Generation:** XcodeGen (`project.yml`)
- **CI/CD:** Xcode Cloud with `ci_scripts/ci_post_clone.sh`
- **Code Quality:** SwiftLint + SwiftFormat
- **Build Automation:** Fastlane for screenshots
