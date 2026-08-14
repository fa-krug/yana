# Remove Server Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user un-pair this device from its Yana Server, with a confirmation that explicitly
warns about local data loss and the demo-content fallback.

**Architecture:** A new `ServerDisconnect` service composes three already-tested primitives
(`KeychainService.deleteDeviceToken()`, `LocalLibraryReset.wipe(context:)`,
`ScreenshotSeed.seed(into:)`) plus two `AppSettings` writes, mirroring the shape of the existing
`PairingSync` service. `ServerSettingsSection` (shared by iOS and Mac Settings) gets a new
destructive row that confirms via a native SwiftUI alert before calling it.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`import Testing`, `@Test`/`#expect`).

## Global Constraints

- Every new user-facing string needs both an `en`-implicit (the key itself) and a `"de"` entry in
  `Yana/Resources/Localizable.xcstrings`, each marked `"state": "translated"`. German follows
  Apple's infinitive/no-"Du"-or-"Sie" style.
- User-facing copy must read as natural prose — no bullet points, no em/en dashes as a rhetorical
  device (this rule does not apply to code comments or this plan).
- Swift 6 strict concurrency: new UI-facing types touching `AppSettings`/`ModelContext` must be
  `@MainActor`.
- Tests use the Swift Testing framework (`@Test`, `#expect`), not XCTest, matching every existing
  file under `YanaTests/`.

---

### Task 1: `ServerDisconnect` service

**Files:**
- Create: `Yana/Services/ServerDisconnect.swift`
- Test: `YanaTests/ServerDisconnectTests.swift`

**Interfaces:**
- Consumes: `KeychainService.saveDeviceToken(_:)` / `.loadDeviceToken()` / `.deleteDeviceToken()`
  (`Yana/Services/KeychainService.swift`, all `static`, no `self`); `AppSettings.serverBaseURL: String`
  and `AppSettings.hasSkippedServerPairing: Bool` (`Yana/Models/AppSettings.swift`);
  `LocalLibraryReset.wipe(context: ModelContext)` (`Yana/Utilities/LocalLibraryReset.swift`, `@MainActor static`);
  `ScreenshotSeed.seed(into: ModelContext) async` (`Yana/Utilities/ScreenshotSeed.swift`, `static`).
- Produces: `ServerDisconnect.disconnect(settings: AppSettings, context: ModelContext = AppContainer.shared.mainContext)`,
  a `@MainActor static func` — this is the exact call `ServerSettingsSection` (Task 2) invokes from
  its confirmation alert's destructive action.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ServerDisconnectTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import Yana

@MainActor
struct ServerDisconnectTests {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func disconnectClearsCredentialsWipesLibraryAndEntersDemoMode() throws {
        let context = try inMemoryContext()
        let feed = Feed(name: "Paired Feed", aggregator: "feedContent", identifier: "paired://feed")
        context.insert(feed)
        let article = Article(
            title: "Paired Article", identifier: "paired://article/0",
            url: "https://example.com", date: .now, author: "Someone"
        )
        article.feed = feed
        context.insert(article)
        try context.save()

        KeychainService.saveDeviceToken("test-session-token")
        defer { KeychainService.deleteDeviceToken() }

        let settings = AppSettings()
        settings.serverBaseURL = "https://paired.example.com"
        settings.hasSkippedServerPairing = false
        defer {
            settings.serverBaseURL = ""
            settings.hasSkippedServerPairing = false
        }

        ServerDisconnect.disconnect(settings: settings, context: context)

        #expect(KeychainService.loadDeviceToken() == nil)
        #expect(settings.serverBaseURL == "")
        #expect(settings.hasSkippedServerPairing == true)
        #expect(try context.fetch(FetchDescriptor<Article>()).allSatisfy { $0.identifier != "paired://article/0" })
        #expect(try context.fetch(FetchDescriptor<Feed>()).allSatisfy { $0.identifier != "paired://feed" })
    }
}
```

Note: this asserts the wipe happened synchronously (the paired feed/article are gone right after
`disconnect()` returns), not that the context ends up empty — `ScreenshotSeed.seed(into:)` runs in
a fire-and-forget `Task` afterward and may or may not have inserted its own demo `Feed`/`Article`
rows by the time the assertion runs, so asserting a fully empty context would be flaky.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ServerDisconnectTests`
Expected: FAIL to compile — `ServerDisconnect` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `Yana/Services/ServerDisconnect.swift`:

```swift
import Foundation
import SwiftData

/// Un-pairs this device from its Yana Server: deletes the stored Bearer token, clears the server
/// address, wipes every locally mirrored `Article`/`Feed`/`Tag`, and falls back into the same
/// demo-content mode `OnboardingServerPage`'s "Skip for now" already offers -- see
/// docs/superpowers/specs/2026-08-14-remove-server-connection-design.md. Mirrors `PairingSync`'s
/// shape, just running the transition in reverse.
enum ServerDisconnect {
    @MainActor
    static func disconnect(settings: AppSettings, context: ModelContext = AppContainer.shared.mainContext) {
        KeychainService.deleteDeviceToken()
        settings.serverBaseURL = ""
        LocalLibraryReset.wipe(context: context)
        settings.hasSkippedServerPairing = true
        Task {
            await ScreenshotSeed.seed(into: context)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ServerDisconnectTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/ServerDisconnect.swift YanaTests/ServerDisconnectTests.swift
git commit -m "Add ServerDisconnect service for un-pairing a device"
```

---

### Task 2: Settings UI — "Remove Server Connection" row + confirmation alert

**Files:**
- Modify: `Yana/Views/Config/Settings/ServerSettingsSection.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ServerDisconnect.disconnect(settings: AppSettings, context: ModelContext)` (Task 1);
  `AuthenticatedClient.current(settings: AppSettings = AppSettings())` (`Yana/Services/AuthenticatedClient.swift`,
  `@MainActor static`) to decide whether the row is shown at all.
- Produces: nothing consumed by a later task — this is the last task in the plan.

- [ ] **Step 1: Add the row, alert state, and localized strings**

Replace the full contents of `Yana/Views/Config/Settings/ServerSettingsSection.swift`:

```swift
import SwiftUI

/// Shows the currently paired server host and lets the user re-pair against a different one.
/// Reuses `OnboardingServerPage`'s sign-in flow (the same WebView pairing `DevicePairingView`
/// drives) as a sheet — changing servers always requires signing in again, since the Bearer
/// token in Keychain is only valid against the server that issued it.
struct ServerSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var isChangingServer = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        Section {
            Button {
                isChangingServer = true
            } label: {
                HStack {
                    Label("Server", systemImage: "server.rack")
                        .labelStyle(.tintedIcon(.green))
                    Spacer()
                    Text(displayHost)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.server")
            .sheet(isPresented: $isChangingServer) {
                NavigationStack {
                    OnboardingServerPage(onPaired: { isChangingServer = false }, isOnboardingFlow: false)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { isChangingServer = false } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel(Text("Close"))
                            }
                        }
                }
            }

            if isPaired {
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Text("Remove Server Connection")
                }
                .accessibilityIdentifier("settings.removeServerConnection")
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Changing the server requires signing in again.")
        }
        .alert(
            String(localized: "Remove Server Connection?"),
            isPresented: $isConfirmingRemoval
        ) {
            Button(String(localized: "Remove Server Connection"), role: .destructive) {
                ServerDisconnect.disconnect(settings: settings, context: modelContext)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This deletes all articles stored on this device and switches to demo content until you pair a server again.")
        }
    }

    private var isPaired: Bool {
        AuthenticatedClient.current(settings: settings) != nil
    }

    private var displayHost: String {
        URL(string: settings.serverBaseURL)?.host ?? settings.serverBaseURL
    }
}

#Preview {
    Form { ServerSettingsSection() }
        .environment(AppSettings())
}
```

- [ ] **Step 2: Add the two new localized strings**

Open `Yana/Resources/Localizable.xcstrings`. Find the `"Remove Empty Elements"` entry (search for
`"Remove Empty Elements": {`) and insert two new entries immediately before it, keeping the
existing alphabetical-ish ordering of keys in this file:

```json
    "Remove Server Connection": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Serververbindung entfernen"
          }
        }
      }
    },
    "Remove Server Connection?": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Serververbindung entfernen?"
          }
        }
      }
    },
    "This deletes all articles stored on this device and switches to demo content until you pair a server again.": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Dadurch werden alle auf diesem Gerät gespeicherten Artikel gelöscht und bis zur erneuten Kopplung mit einem Server Demoinhalte angezeigt."
          }
        }
      }
    },
```

`"Cancel"` already exists and is already translated — no change needed there.

- [ ] **Step 3: Validate the string catalog is still well-formed JSON**

Run: `plutil -lint Yana/Resources/Localizable.xcstrings`
Expected: `Yana/Resources/Localizable.xcstrings: OK`

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all tests pass, including the new `ServerDisconnectTests` from Task 1.

- [ ] **Step 6: Manual check in the simulator**

Launch the app in the iPhone 17 simulator (paired against any reachable test server, or by
manually setting `AppSettings().serverBaseURL` and a Keychain token via a debug breakpoint if no
test server is available). Open Settings, confirm the red "Remove Server Connection" row appears
below the server row only while paired. Tap it, confirm the alert reads "Remove Server
Connection?" with the message mentioning both article deletion and demo content, tap "Remove
Server Connection" in the alert, and confirm: the row disappears (no longer paired), the timeline
now shows the seeded demo articles, and `DemoModeBanner` appears with its "Pair Now" action.

- [ ] **Step 7: Commit**

```bash
git add Yana/Views/Config/Settings/ServerSettingsSection.swift Yana/Resources/Localizable.xcstrings
git commit -m "Add Remove Server Connection action to Settings"
```

---

## Self-Review Notes

- **Spec coverage:** confirmation dialog mentioning both data loss and demo mode (Task 2, Step 1) ✓;
  reuse of `LocalLibraryReset`/`ScreenshotSeed`/`hasSkippedServerPairing` (Task 1) ✓; row only shown
  while paired (Task 2, Step 1's `if isPaired`) ✓; localization (Task 2, Step 2) ✓; test coverage
  (Task 1) ✓.
- **Type consistency:** `ServerDisconnect.disconnect(settings:context:)` is defined once in Task 1
  and called with the same two labeled arguments in Task 2 — no signature drift.
- **No placeholders:** every step has literal file contents or exact shell commands.
