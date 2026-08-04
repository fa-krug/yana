# Pre-2.0 Server Migration Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a dismissable, full-screen notice — once, at launch — to devices that already
completed onboarding before Yana 2.0.0, telling them Yana now requires a server, with an escape
hatch (build v1.1.0 yourself) and a refund contact. A restore row in Settings → About (visible
only to those same devices) can bring it back on demand.

**Architecture:** A pure, unit-tested state-transition enum (`ServerMigrationEligibility`)
decides eligibility and auto-show/restore rules from three new `AppSettings` flags. `ContentView`
evaluates eligibility once at launch and presents a new `ServerMigrationNoticeView` — via
`.fullScreenCover` on iOS, via its own `WindowGroup` on Mac Catalyst (mirroring the existing
`WelcomeView`/`WelcomeWindowRoot` split). A new row in `AboutSettingsSection`, gated on the same
eligibility flag, re-presents it on demand.

**Tech Stack:** SwiftUI, `@Observable` `AppSettings` (UserDefaults-backed), Swift Testing
(`import Testing`, `@Test`, `#expect`), XcodeGen, static HTML/CSS/JS site under `docs/site/`.

## Global Constraints

- Every new user-facing string must be added to `Yana/Resources/Localizable.xcstrings` with a
  German translation marked `"state": "translated"` in the same task that introduces the string
  — never left English-only (project rule).
- German copy follows Apple's style: infinitive for actions/instructions, no "Du"/"Sie".
- After adding any new `.swift` file under `Yana/` or `YanaTests/`, run `xcodegen generate`
  before building — XcodeGen globs folders into the `.xcodeproj`, so a new file is invisible to
  `xcodebuild` until regenerated.
- Bundle identifier for manual `defaults`/`simctl` verification: `de.fa-krug.Yana`.
- Build/test destination throughout: `platform=iOS Simulator,name=iPhone 17`.
- Design reference: `docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md`.

---

## Task 1: Pure eligibility/state logic

**Files:**
- Create: `Yana/Models/ServerMigrationEligibility.swift`
- Test: `YanaTests/ServerMigrationEligibilityTests.swift`

**Interfaces:**
- Produces: `enum ServerMigrationEligibility { struct State: Equatable { var hasEvaluated: Bool =
  false; var isPreServerMigrationUser: Bool = false }; static func evaluate(_ state: State,
  hasCompletedOnboarding: Bool) -> State; static func shouldAutoShow(isPreServerMigrationUser:
  Bool, hasDismissedNotice: Bool) -> Bool; static func canRestore(isPreServerMigrationUser: Bool)
  -> Bool }` — used by Task 3 (auto-show at launch) and Task 5 (About restore row).

- [ ] **Step 1: Write the failing tests**

Create `YanaTests/ServerMigrationEligibilityTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

struct ServerMigrationEligibilityTests {

    @Test func firstEvaluationOfAnExistingUserMarksThemPreServerMigration() {
        let state = ServerMigrationEligibility.evaluate(.init(), hasCompletedOnboarding: true)
        #expect(state.hasEvaluated == true)
        #expect(state.isPreServerMigrationUser == true)
    }

    @Test func firstEvaluationOfAFreshInstallDoesNotMarkThemPreServerMigration() {
        let state = ServerMigrationEligibility.evaluate(.init(), hasCompletedOnboarding: false)
        #expect(state.hasEvaluated == true)
        #expect(state.isPreServerMigrationUser == false)
    }

    @Test func secondEvaluationIsANoOpEvenIfOnboardingFinishedSince() {
        let firstPass = ServerMigrationEligibility.evaluate(.init(), hasCompletedOnboarding: false)
        #expect(firstPass.isPreServerMigrationUser == false)

        // A fresh install completes onboarding later in the same run — must not be reclassified.
        let secondPass = ServerMigrationEligibility.evaluate(firstPass, hasCompletedOnboarding: true)
        #expect(secondPass.isPreServerMigrationUser == false)
        #expect(secondPass.hasEvaluated == true)
    }

    @Test func autoShowRequiresEligibilityAndNoPriorDismissal() {
        #expect(ServerMigrationEligibility.shouldAutoShow(isPreServerMigrationUser: true, hasDismissedNotice: false) == true)
        #expect(ServerMigrationEligibility.shouldAutoShow(isPreServerMigrationUser: true, hasDismissedNotice: true) == false)
        #expect(ServerMigrationEligibility.shouldAutoShow(isPreServerMigrationUser: false, hasDismissedNotice: false) == false)
    }

    @Test func restoreRowOnlyShowsForPreServerMigrationUsers() {
        #expect(ServerMigrationEligibility.canRestore(isPreServerMigrationUser: true) == true)
        #expect(ServerMigrationEligibility.canRestore(isPreServerMigrationUser: false) == false)
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project and run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:YanaTests/ServerMigrationEligibilityTests
```

Expected: build FAILS — `ServerMigrationEligibility` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `Yana/Models/ServerMigrationEligibility.swift`:

```swift
import Foundation

/// Pure state-transition logic for the pre-2.0 "Yana now requires a server" notice, kept free of
/// SwiftUI/AppSettings so the rules are directly testable. See
/// docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md.
enum ServerMigrationEligibility {
    struct State: Equatable {
        var hasEvaluated: Bool = false
        var isPreServerMigrationUser: Bool = false
    }

    /// Classifies this device exactly once: a device that had already completed onboarding
    /// before this code ever ran (i.e. under the old, server-free flow) is a "pre-server-migration
    /// user". Once evaluated, later calls are no-ops — a fresh install that finishes onboarding
    /// *after* this code shipped must never be reclassified.
    static func evaluate(_ state: State, hasCompletedOnboarding: Bool) -> State {
        guard !state.hasEvaluated else { return state }
        return State(hasEvaluated: true, isPreServerMigrationUser: hasCompletedOnboarding)
    }

    /// Whether the notice should auto-show at launch.
    static func shouldAutoShow(isPreServerMigrationUser: Bool, hasDismissedNotice: Bool) -> Bool {
        isPreServerMigrationUser && !hasDismissedNotice
    }

    /// Whether the Settings → About "Server Update Notice" restore row should be shown.
    static func canRestore(isPreServerMigrationUser: Bool) -> Bool {
        isPreServerMigrationUser
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:YanaTests/ServerMigrationEligibilityTests
```

Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/ServerMigrationEligibility.swift YanaTests/ServerMigrationEligibilityTests.swift
git commit -m "Add pure eligibility logic for the pre-2.0 server migration notice"
```

---

## Task 2: `ServerMigrationNoticeView` + its localized strings

**Files:**
- Create: `Yana/Views/ServerMigrationNoticeView.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct ServerMigrationNoticeView: View { var onDismiss: () -> Void }` — used by Task 3
  (iOS `.fullScreenCover`) and Task 4 (Mac `ServerMigrationNoticeWindowRoot`).

- [ ] **Step 1: Create the view**

Create `Yana/Views/ServerMigrationNoticeView.swift`:

```swift
import SwiftUI

/// Full-screen, dismissable notice shown once to devices that already completed onboarding
/// before Yana required a server (see `ServerMigrationEligibility` and the design doc at
/// docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md). Presented both as an
/// iOS `.fullScreenCover` (`ContentView`) and inside its own Mac window
/// (`ServerMigrationNoticeWindowRoot`).
struct ServerMigrationNoticeView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Yana Now Requires a Server")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Starting with this version, Yana needs to connect to a Yana Server to fetch and manage your feeds and articles.")
                        Link(destination: URL(string: "https://yana.fa-krug.de/server.html")!) {
                            Text("Learn more about the Yana Server")
                        }

                        Text("Would rather not switch? Yana 1.1.0 — the last fully self-contained, server-free release — remains open source.")
                        Link(destination: URL(string: "https://github.com/fa-krug/yana/releases/tag/v1.1.0")!) {
                            Text("Build Yana 1.1.0 from Source")
                        }

                        Text("Don't want to use Yana anymore?")
                        Link(destination: URL(string: "mailto:info@fa-krug.de")!) {
                            Text("Email info@fa-krug.de for a Refund")
                        }
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
            }
            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var footer: some View {
        Button(action: onDismiss) {
            Text("Got It")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("serverMigrationNoticeDismissButton")
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

#Preview {
    ServerMigrationNoticeView(onDismiss: {})
}
```

- [ ] **Step 2: Add the localized strings**

In `Yana/Resources/Localizable.xcstrings`, find `"Show Welcome Screen Again": {` (around line
3280) and insert the eight new entries immediately **before** it (English is the source language,
so only a `de` localization block is needed per key — see the existing entry right above for the
exact shape to copy):

```json
    "Yana Now Requires a Server": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Yana benötigt jetzt einen Server"
          }
        }
      }
    },
    "Starting with this version, Yana needs to connect to a Yana Server to fetch and manage your feeds and articles.": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Ab dieser Version benötigt Yana eine Verbindung zu einem Yana-Server, um Feeds und Artikel abzurufen und zu verwalten."
          }
        }
      }
    },
    "Learn more about the Yana Server": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Mehr über den Yana-Server erfahren"
          }
        }
      }
    },
    "Would rather not switch? Yana 1.1.0 — the last fully self-contained, server-free release — remains open source.": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Kein Wechsel gewünscht? Yana 1.1.0 – die letzte vollständig eigenständige, serverlose Version – bleibt Open Source."
          }
        }
      }
    },
    "Build Yana 1.1.0 from Source": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Yana 1.1.0 aus dem Quellcode selbst bauen"
          }
        }
      }
    },
    "Don't want to use Yana anymore?": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Yana nicht mehr nutzen?"
          }
        }
      }
    },
    "Email info@fa-krug.de for a Refund": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Für eine Rückerstattung an info@fa-krug.de schreiben"
          }
        }
      }
    },
    "Got It": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Verstanden"
          }
        }
      }
    },
```

- [ ] **Step 3: Regenerate the project and build**

```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED. Confirm `Yana/Resources/Localizable.xcstrings` is still valid JSON
(Xcode will refuse to open the project otherwise): `python3 -c "import json; json.load(open('Yana/Resources/Localizable.xcstrings'))"` must print nothing and exit 0.

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/ServerMigrationNoticeView.swift Yana/Resources/Localizable.xcstrings
git commit -m "Add ServerMigrationNoticeView with its localized copy"
```

---

## Task 3: Wire the notice into iOS launch + `AppSettings`/`AppState` flags

**Files:**
- Modify: `Yana/Models/AppSettings.swift:153` (Key), `Yana/Models/AppSettings.swift:418` (properties)
- Modify: `Yana/Models/AppState.swift`
- Modify: `Yana/ContentView.swift`

**Interfaces:**
- Consumes: `ServerMigrationEligibility.evaluate`/`.shouldAutoShow` (Task 1),
  `ServerMigrationNoticeView` (Task 2).
- Produces: `AppSettings.hasEvaluatedServerMigrationEligibility: Bool`,
  `AppSettings.isPreServerMigrationUser: Bool`, `AppSettings.hasDismissedServerMigrationNotice:
  Bool`, `AppState.showServerMigrationNotice: Bool` — all consumed by Task 4 (Mac) and Task 5
  (About restore row).

- [ ] **Step 1: Add the three `AppSettings` flags**

In `Yana/Models/AppSettings.swift`, inside the `Key` struct, right after the `// Onboarding` /
`static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"` line (line 153), add:

```swift
        // Server migration notice
        static let hasEvaluatedServerMigrationEligibility = "settings.hasEvaluatedServerMigrationEligibility"
        static let isPreServerMigrationUser = "settings.isPreServerMigrationUser"
        static let hasDismissedServerMigrationNotice = "settings.hasDismissedServerMigrationNotice"
```

Right after the `hasCompletedOnboarding` computed property (after line 418's closing brace), add:

```swift

    // MARK: Server Migration Notice
    /// One-time flag: whether this device's pre-server-migration eligibility has been evaluated.
    var hasEvaluatedServerMigrationEligibility: Bool {
        get { access(keyPath: \.hasEvaluatedServerMigrationEligibility); return defaults.bool(forKey: Key.hasEvaluatedServerMigrationEligibility) }
        set { withMutation(keyPath: \.hasEvaluatedServerMigrationEligibility) { defaults.set(newValue, forKey: Key.hasEvaluatedServerMigrationEligibility) } }
    }
    /// Whether this device had already completed onboarding before Yana required a server.
    var isPreServerMigrationUser: Bool {
        get { access(keyPath: \.isPreServerMigrationUser); return defaults.bool(forKey: Key.isPreServerMigrationUser) }
        set { withMutation(keyPath: \.isPreServerMigrationUser) { defaults.set(newValue, forKey: Key.isPreServerMigrationUser) } }
    }
    /// Whether the "Yana now requires a server" notice has been dismissed.
    var hasDismissedServerMigrationNotice: Bool {
        get { access(keyPath: \.hasDismissedServerMigrationNotice); return defaults.bool(forKey: Key.hasDismissedServerMigrationNotice) }
        set { withMutation(keyPath: \.hasDismissedServerMigrationNotice) { defaults.set(newValue, forKey: Key.hasDismissedServerMigrationNotice) } }
    }
```

- [ ] **Step 2: Add the `AppState` flag**

In `Yana/Models/AppState.swift`, add `var showServerMigrationNotice = false` next to the existing
`var showWelcome = false`:

```swift
    var showWelcome = false
    var showServerMigrationNotice = false
```

- [ ] **Step 3: Wire `ContentView`**

In `Yana/ContentView.swift`, inside the iOS branch's view chain (after the existing
`.fullScreenCover(isPresented: $appState.showWelcome) { ... }`), add a second cover:

```swift
                    .fullScreenCover(isPresented: $appState.showWelcome) {
                        WelcomeView(onFinish: {
                            settings.hasCompletedOnboarding = true
                            appState.showWelcome = false
                        })
                        .interactiveDismissDisabled()
                    }
                    .fullScreenCover(isPresented: $appState.showServerMigrationNotice) {
                        ServerMigrationNoticeView(onDismiss: {
                            settings.hasDismissedServerMigrationNotice = true
                            appState.showServerMigrationNotice = false
                        })
                        .interactiveDismissDisabled()
                    }
```

Then, in the same file's `.onAppear`, add the eligibility check and auto-show trigger. Insert it
right after the existing `-UITEST_RESET_ONBOARDING` block and before the existing `if
!settings.hasCompletedOnboarding, ...` welcome check:

```swift
            if !settings.hasEvaluatedServerMigrationEligibility {
                let evaluated = ServerMigrationEligibility.evaluate(
                    .init(
                        hasEvaluated: settings.hasEvaluatedServerMigrationEligibility,
                        isPreServerMigrationUser: settings.isPreServerMigrationUser
                    ),
                    hasCompletedOnboarding: settings.hasCompletedOnboarding
                )
                settings.hasEvaluatedServerMigrationEligibility = evaluated.hasEvaluated
                settings.isPreServerMigrationUser = evaluated.isPreServerMigrationUser
            }
            if ServerMigrationEligibility.shouldAutoShow(
                isPreServerMigrationUser: settings.isPreServerMigrationUser,
                hasDismissedNotice: settings.hasDismissedServerMigrationNotice
            ) {
                appState.showServerMigrationNotice = true
            }
```

(This unconditionally sets `appState.showServerMigrationNotice` regardless of platform. On Mac
that flag currently has no reader — `MacRootView` doesn't observe it — so this is a harmless no-op
there until Task 4 adds the Mac-specific branch.)

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manually verify both paths in the Simulator**

Boot the simulator and install a fresh build, then verify the **new-install path never shows the
notice**:

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl erase "iPhone 17"
xcrun simctl boot "iPhone 17"
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/yana-build build
xcrun simctl install "iPhone 17" /tmp/yana-build/Build/Products/Debug-iphonesimulator/Yana.app
xcrun simctl launch "iPhone 17" de.fa-krug.Yana
```

Expected: the Welcome onboarding screen appears (fresh install: `hasCompletedOnboarding` was
`false` at the first eligibility check, so `isPreServerMigrationUser` is `false`). The server
notice must **not** appear now or on any later relaunch.

Then verify the **existing-user path** by simulating a device that already had
`hasCompletedOnboarding == true` before this build ever ran:

```bash
xcrun simctl terminate "iPhone 17" de.fa-krug.Yana
xcrun simctl spawn "iPhone 17" defaults write de.fa-krug.Yana settings.hasCompletedOnboarding -bool YES
xcrun simctl spawn "iPhone 17" defaults write de.fa-krug.Yana settings.hasEvaluatedServerMigrationEligibility -bool NO
xcrun simctl spawn "iPhone 17" defaults write de.fa-krug.Yana settings.hasDismissedServerMigrationNotice -bool NO
xcrun simctl launch "iPhone 17" de.fa-krug.Yana
```

Expected: the server migration notice appears full-screen on launch (no Welcome screen, since
`hasCompletedOnboarding` is `true`). Tap "Got It" — the notice dismisses. Terminate and relaunch
the app again: the notice must **not** reappear (dismissed flag is now persisted).

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/Models/AppState.swift Yana/ContentView.swift
git commit -m "Auto-show the server migration notice once for existing iOS users"
```

---

## Task 4: Mac Catalyst window

**Files:**
- Modify: `Yana/Reader/Mac/WindowID.swift`
- Create: `Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift`
- Modify: `Yana/YanaApp.swift`
- Modify: `Yana/ContentView.swift`

**Interfaces:**
- Consumes: `ServerMigrationNoticeView` (Task 2), `AppSettings.isPreServerMigrationUser` /
  `.hasDismissedServerMigrationNotice` (Task 3).
- Produces: `WindowID.serverNotice: String`, `struct ServerMigrationNoticeWindowRoot: View` — used
  by Task 5's Mac wiring.

- [ ] **Step 1: Add the window identifier**

In `Yana/Reader/Mac/WindowID.swift`, add a third identifier next to `.settings`/`.welcome`:

```swift
enum WindowID {
    static let settings = "settings"
    static let welcome = "welcome"
    static let serverNotice = "serverNotice"
}
```

- [ ] **Step 2: Create the Mac window host**

Create `Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift`:

```swift
import SwiftUI

/// Hosts `ServerMigrationNoticeView` in its own Mac window, mirroring `WelcomeWindowRoot`. If the
/// window is restored after the notice has already been dismissed (Mac Catalyst can restore
/// windows left open at last quit), it closes itself immediately.
struct ServerMigrationNoticeWindowRoot: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()

    var body: some View {
        ServerMigrationNoticeView(onDismiss: {
            settings.hasDismissedServerMigrationNotice = true
            dismiss()
        })
        .toggleStyle(.switch)
        .onAppear {
            if settings.hasDismissedServerMigrationNotice { dismiss() }
        }
    }
}
```

- [ ] **Step 3: Register the window in `YanaApp`**

In `Yana/YanaApp.swift`, inside the existing `#if targetEnvironment(macCatalyst)` block, right
after the `WindowGroup(id: WindowID.welcome, ...)` declaration, add:

```swift
        WindowGroup(id: WindowID.serverNotice, for: Bool.self) { _ in
            ServerMigrationNoticeWindowRoot()
        }
        .modelContainer(AppContainer.shared)
        .defaultSize(width: 640, height: 560)
```

- [ ] **Step 4: Make `ContentView`'s auto-show branch platform-aware**

In `Yana/ContentView.swift`, replace the unconditional line added in Task 3,

```swift
                appState.showServerMigrationNotice = true
```

with:

```swift
                if isMac {
                    openWindow(id: WindowID.serverNotice, value: true)
                } else {
                    appState.showServerMigrationNotice = true
                }
```

- [ ] **Step 5: Build for both destinations**

```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build
```

Expected: both BUILD SUCCEEDED. (Per prior findings in this codebase, a Mac Catalyst build can be
compiled but not launched from this shell — codesigning needs an unlocked keychain in an
interactive Terminal session. Compiling successfully is the deliverable for this step; note in the
task handoff that a human should launch the Mac build once to confirm the window opens and
self-closes correctly per Step 2's guard.)

- [ ] **Step 6: Commit**

```bash
git add Yana/Reader/Mac/WindowID.swift Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift \
  Yana/YanaApp.swift Yana/ContentView.swift
git commit -m "Add Mac Catalyst window for the server migration notice"
```

---

## Task 5: Settings → About restore row (all platforms)

**Files:**
- Modify: `Yana/Views/Config/Settings/AboutSettingsSection.swift`
- Modify: `Yana/Views/Config/SettingsScreenView.swift`
- Modify: `Yana/Reader/ReaderHostView.swift`
- Modify: `Yana/Reader/Mac/MacSettingsWindow.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ServerMigrationEligibility.canRestore` (Task 1), `WindowID.serverNotice` (Task 4),
  `AppSettings.isPreServerMigrationUser`/`.hasDismissedServerMigrationNotice` (Task 3).
- Produces: nothing consumed by later tasks — this is the last code task.

- [ ] **Step 1: Add the restore row to `AboutSettingsSection`**

In `Yana/Views/Config/Settings/AboutSettingsSection.swift`, add a new callback parameter next to
`onRestartOnboarding`:

```swift
    var onRestartOnboarding: () -> Void = {}
    var onShowServerNotice: () -> Void = {}
```

Then add a new row right after the existing "Show Welcome Screen Again" button (inside the same
`Section`):

```swift
            Button {
                settings.hasCompletedOnboarding = false
                onRestartOnboarding()
            } label: {
                Label("Show Welcome Screen Again", systemImage: "sparkles")
                    .labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.showWelcome")
            if ServerMigrationEligibility.canRestore(isPreServerMigrationUser: settings.isPreServerMigrationUser) {
                Button {
                    settings.hasDismissedServerMigrationNotice = false
                    onShowServerNotice()
                } label: {
                    Label("Server Update Notice", systemImage: "server.rack")
                        .labelStyle(.tintedIcon(.blue))
                }
                .accessibilityIdentifier("settings.showServerNotice")
            }
```

- [ ] **Step 2: Thread the callback through the iOS Settings screen**

In `Yana/Views/Config/SettingsScreenView.swift`, add the new parameter and thread it to
`AboutSettingsSection`:

```swift
struct SettingsScreenView: View {
    var onRestartOnboarding: () -> Void = {}
    var onShowServerNotice: () -> Void = {}
```

```swift
            AboutSettingsSection(
                onRestartOnboarding: {
                    onRestartOnboarding()
                    dismiss()
                },
                onShowServerNotice: {
                    onShowServerNotice()
                    dismiss()
                },
                onRevealDiagnostics: {
                }
            )
```

- [ ] **Step 3: Wire the iOS presenter (`ReaderHostView`)**

In `Yana/Reader/ReaderHostView.swift`, add a pending flag next to `restartOnboardingPending`:

```swift
    /// Set by the Settings "Show Welcome Screen Again" row; consumed once the Settings sheet has
    /// fully dismissed so the welcome cover presents cleanly (no stacked-presentation race).
    @State private var restartOnboardingPending = false
    /// Same pattern as `restartOnboardingPending`, for the Settings "Server Update Notice" row.
    @State private var showServerNoticePending = false
```

Then update the Settings sheet's `onDismiss` and content closure:

```swift
        .sheet(isPresented: $appState.showSettings, onDismiss: {
            if restartOnboardingPending {
                restartOnboardingPending = false
                appState.showWelcome = true
            }
            if showServerNoticePending {
                showServerNoticePending = false
                appState.showServerMigrationNotice = true
            }
        }) {
            NavigationStack {
                SettingsScreenView(
                    onRestartOnboarding: { restartOnboardingPending = true },
                    onShowServerNotice: { showServerNoticePending = true }
                )
            }
        }
```

- [ ] **Step 4: Wire the Mac presenter (`MacSettingsWindow`)**

In `Yana/Reader/Mac/MacSettingsWindow.swift`, update the `.about` case:

```swift
        case .about:
            Form {
                AboutSettingsSection(
                    onRestartOnboarding: {
                        openWindow(id: WindowID.welcome, value: true)
                        dismiss()
                    },
                    onShowServerNotice: {
                        openWindow(id: WindowID.serverNotice, value: true)
                        dismiss()
                    },
                    onRevealDiagnostics: {
                        diagnosticsRevealed = true
                        selection = .diagnostics
                    }
                )
            }
```

- [ ] **Step 5: Add the row's localized string**

In `Yana/Resources/Localizable.xcstrings`, add one more entry (same insertion point as Task 2,
immediately before `"Show Welcome Screen Again": {`):

```json
    "Server Update Notice": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "Hinweis zum Server-Update"
          }
        }
      }
    },
```

- [ ] **Step 6: Build**

```bash
xcodegen generate
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Manually verify the restore row in the Simulator**

Reusing the "existing-user" simulator state from Task 3 Step 5 (or re-applying the same three
`defaults write` commands), dismiss the notice once, then:

```bash
xcrun simctl launch "iPhone 17" de.fa-krug.Yana
```

Open Settings → About. Expected: a "Server Update Notice" row is visible (blue server-rack icon).
Tap it — the Settings sheet dismisses and the server migration notice reappears. Now reset to a
**fresh-install** state (`isPreServerMigrationUser` stays `false`) and confirm the row is **absent**
from About for that device.

- [ ] **Step 8: Commit**

```bash
git add Yana/Views/Config/Settings/AboutSettingsSection.swift Yana/Views/Config/SettingsScreenView.swift \
  Yana/Reader/ReaderHostView.swift Yana/Reader/Mac/MacSettingsWindow.swift Yana/Resources/Localizable.xcstrings
git commit -m "Add a Settings restore row for the server migration notice"
```

---

## Task 6: Marketing site page (`docs/site/server.html`)

**Files:**
- Create: `docs/site/server.html`
- Modify: `docs/site/index.html`

**Interfaces:**
- Consumes: nothing from earlier tasks (static HTML, referenced by URL only from
  `ServerMigrationNoticeView`, already hardcoded there in Task 2).
- Produces: nothing consumed by other tasks — this is the last task in the plan.

- [ ] **Step 1: Create the bilingual server page**

Create `docs/site/server.html`, matching `privacy.html`'s skeleton (anti-flash inline script,
header, `.legal`/`.wrap` content container, `lang-en`/`lang-de` divs) with real content drawn from
`yana-server`'s own README (self-hosted only, no pricing/hosted plan, MIT-licensed):

```html
<!DOCTYPE html>
<html lang="en" data-lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Yana Server — Yana</title>
    <meta name="description" content="Yana Server: a free, self-hosted, open-source RSS/YouTube/Reddit/podcast aggregator that powers the Yana app." />
    <link rel="icon" href="assets/img/app-icon.svg" type="image/svg+xml" />
    <link rel="apple-touch-icon" href="assets/img/app-icon.svg" />
    <link rel="stylesheet" href="assets/styles.css" />
    <script>
      (function () {
        try {
          var l = localStorage.getItem("yana-lang") || navigator.language;
          l = (l || "en").toLowerCase().slice(0, 2);
          if (l !== "de") l = "en";
          document.documentElement.setAttribute("data-lang", l);
          document.documentElement.setAttribute("lang", l);
        } catch (e) {}
      })();
    </script>
  </head>
  <body>
    <header class="site-header">
      <div class="wrap">
        <a class="brand" href="index.html"><img class="brand-mark" src="assets/img/app-icon.svg" alt="Yana app icon" /> Yana</a>
        <div class="header-tools" style="margin-left: auto;">
          <div class="lang-switch" role="group" aria-label="Language">
            <button type="button" data-set="en">EN</button>
            <button type="button" data-set="de">DE</button>
          </div>
        </div>
      </div>
    </header>

    <main class="legal">
      <div class="wrap">
        <a class="back-link" href="index.html">← <span class="lang-en">Back to home</span><span class="lang-de">Zurück zur Startseite</span></a>

        <!-- English -->
        <div class="lang-en">
          <h1>Yana Server</h1>
          <p>Starting with Yana 2.0, the app needs a Yana Server to fetch and manage feeds and articles. The server is free, open source, and self-hosted — there is no hosted/managed plan and no pricing.</p>

          <h2>What it is</h2>
          <p>A self-hosted RSS, YouTube, Reddit, and podcast aggregator that powers the Yana iOS/Mac client's feed sync. It's a single process — Next.js, React, TypeScript, and a local SQLite database — with no Redis and no separate worker container.</p>

          <h2>Accounts</h2>
          <p>Sign-in uses passkeys. An administrator account is created the first time the server starts; there is no public self-service sign-up — an administrator provisions each user.</p>

          <h2>Install with npm</h2>
          <pre><code>npm install
npm run dev</code></pre>
          <p>Then open <code>http://localhost:3000</code>.</p>

          <h2>Install with Docker</h2>
          <pre><code>mkdir -p data media &amp;&amp; chown -R 1001:1001 data media
docker compose up --build</code></pre>
          <p>Then open <code>http://localhost:3000</code>.</p>

          <h2>Configuration</h2>
          <p>Copy <code>.env.example</code> to <code>.env</code>. Set <code>BETTER_AUTH_SECRET</code> before any real deployment (for example with <code>openssl rand -base64 32</code>) — it signs session cookies. Optional variables include <code>DATABASE_PATH</code>, <code>MEDIA_PATH</code>, <code>PASSKEY_RP_ID</code>, <code>PUBLIC_URL</code>, <code>TZ</code>, and <code>PORT</code>. Change the default admin account (<code>admin@admin.com</code> / <code>admin</code>) immediately after first login.</p>

          <h2>License</h2>
          <p>MIT-licensed, like the Yana app itself. Source: <a href="https://github.com/fa-krug/yana-server">github.com/fa-krug/yana-server</a>.</p>
        </div>

        <!-- German -->
        <div class="lang-de">
          <h1>Yana-Server</h1>
          <p>Ab Yana 2.0 benötigt die App einen Yana-Server, um Feeds und Artikel abzurufen und zu verwalten. Der Server ist kostenlos, Open Source und wird selbst gehostet — es gibt kein gehostetes Angebot und keine Preise.</p>

          <h2>Was er ist</h2>
          <p>Ein selbst gehosteter RSS-, YouTube-, Reddit- und Podcast-Aggregator, der die Feed-Synchronisierung des Yana-Clients für iOS/Mac antreibt. Ein einziger Prozess — Next.js, React, TypeScript und eine lokale SQLite-Datenbank — ohne Redis und ohne separaten Worker-Container.</p>

          <h2>Konten</h2>
          <p>Die Anmeldung erfolgt per Passkey. Beim ersten Start wird ein Administratorkonto angelegt; eine öffentliche Selbstregistrierung gibt es nicht — ein Administrator legt jedes Konto an.</p>

          <h2>Installation mit npm</h2>
          <pre><code>npm install
npm run dev</code></pre>
          <p>Anschließend <code>http://localhost:3000</code> öffnen.</p>

          <h2>Installation mit Docker</h2>
          <pre><code>mkdir -p data media &amp;&amp; chown -R 1001:1001 data media
docker compose up --build</code></pre>
          <p>Anschließend <code>http://localhost:3000</code> öffnen.</p>

          <h2>Konfiguration</h2>
          <p><code>.env.example</code> nach <code>.env</code> kopieren. Vor jedem echten Einsatz <code>BETTER_AUTH_SECRET</code> setzen (zum Beispiel mit <code>openssl rand -base64 32</code>) — es signiert die Sitzungs-Cookies. Optionale Variablen sind <code>DATABASE_PATH</code>, <code>MEDIA_PATH</code>, <code>PASSKEY_RP_ID</code>, <code>PUBLIC_URL</code>, <code>TZ</code> und <code>PORT</code>. Das Standard-Administratorkonto (<code>admin@admin.com</code> / <code>admin</code>) direkt nach der ersten Anmeldung ändern.</p>

          <h2>Lizenz</h2>
          <p>MIT-lizenziert, wie die Yana-App selbst. Quellcode: <a href="https://github.com/fa-krug/yana-server">github.com/fa-krug/yana-server</a>.</p>
        </div>
      </div>
    </main>

    <script src="assets/app.js"></script>
  </body>
</html>
```

- [ ] **Step 2: Link the new page from the site nav**

In `docs/site/index.html`, add a header nav entry next to `#opensource` (around line 56):

```html
          <a href="#opensource"><span class="lang-en">Open source</span><span class="lang-de">Open Source</span></a>
          <a href="server.html"><span class="lang-en">Server</span><span class="lang-de">Server</span></a>
          <a href="https://github.com/fa-krug/yana">GitHub</a>
```

And add it to the footer "Project" nav (around line 264-266), next to the GitHub link:

```html
            <a href="https://github.com/fa-krug/yana">GitHub</a>
            <a href="server.html"><span class="lang-en">Yana Server</span><span class="lang-de">Yana-Server</span></a>
            <a href="https://github.com/fa-krug/yana/issues"><span class="lang-en">Issues & requests</span><span class="lang-de">Issues & Wünsche</span></a>
```

- [ ] **Step 3: Verify the page renders**

Open the file directly in the Browser pane (`file://` URL to
`docs/site/server.html`) and confirm: the EN/DE toggle in the header switches all content
(including the code blocks) between languages, the back-link returns to `index.html`, and both
`npm` and `docker compose` commands render as monospace code blocks. Also open `index.html` and
confirm the new "Server" nav link (header) and "Yana Server" link (footer) are present and
navigate to `server.html`.

- [ ] **Step 4: Commit**

```bash
git add docs/site/server.html docs/site/index.html
git commit -m "Add a Yana Server page to the marketing site"
```
