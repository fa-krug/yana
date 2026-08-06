# Demo Data Seeding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user skip pairing during onboarding and see realistic seeded demo content instead of
an empty timeline, with a persistent, dismissible reminder that they're viewing demo data until they
pair a real Yana Server.

**Architecture:** Reuse the existing `ScreenshotSeed` fixture library (currently `#if DEBUG`-only,
used for App Store screenshots) as the demo content, gated instead by a new
`AppSettings.hasSkippedServerPairing` flag set when the user taps a new "Skip for now" button on the
onboarding server step. `WelcomeGate` is taught not to force a demo user back into the re-pairing
step on every launch. A new `DemoModeBanner` view, mounted in both the iOS reader and the Mac root
window, reminds the user and offers a one-tap way back into pairing. When a demo user later pairs a
real server, the local demo library is wiped (via a helper extracted from the existing
`UITestReset`) before the first real sync runs.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing (`import Testing`), XcodeGen/xcodebuild.

## Global Constraints

- Every new/changed user-facing string needs an `en` (implicit, via the string literal itself) and a
  `de` entry in `Yana/Resources/Localizable.xcstrings`, `"state": "translated"`, following Apple's
  German localization style (infinitive for actions; no "Du"/"Sie"). This is a hard project rule —
  see project `CLAUDE.md`.
- Swift 6 strict concurrency: any code touching SwiftData's `ModelContext`/`AppSettings` from a
  non-actor-isolated context must stay `@MainActor` (all touched call sites in this plan already are).
- Don't reintroduce the `#if DEBUG` gate on `ScreenshotSeed`/`ScreenshotImageFactory`/
  `ScreenshotLogoFactory` — the whole point of this plan is that this content compiles into release
  builds. Their *automatic* invocation via the `-UITEST_SCREENSHOTS` launch argument stays
  DEBUG-only (unchanged call site in `YanaApp.swift`); only the type definitions lose the gate.
- Follow existing patterns exactly where called out below (e.g. the `restartOnboardingPending`
  mechanism, the `Key`/property-pair shape in `AppSettings`) rather than inventing new idioms.

---

### Task 1: Extract `LocalLibraryReset` from `UITestReset`

**Files:**
- Create: `Yana/Utilities/LocalLibraryReset.swift`
- Modify: `Yana/Utilities/UITestReset.swift`
- Test: `YanaTests/LocalLibraryResetTests.swift`

**Interfaces:**
- Produces: `LocalLibraryReset.wipe(context: ModelContext)` (`@MainActor`, no return value) — deletes
  every local `Article`/`Feed`/`Tag` and clears `AppSettings().timelineAnchorIdentifier`. Used by
  Task 5's pairing-cleanup and by the now-thinner `UITestReset`.

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/LocalLibraryResetTests.swift
import Foundation
import Testing
import SwiftData
@testable import Yana

@MainActor
struct LocalLibraryResetTests {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func wipeDeletesArticlesFeedsAndTagsAndClearsTheAnchor() throws {
        let context = try inMemoryContext()
        let feed = Feed(name: "Demo Feed", aggregator: "feedContent", identifier: "demo://feed")
        context.insert(feed)
        let tag = Tag(name: "Demo", colorHex: "#2E77D0")
        context.insert(tag)
        let article = Article(
            title: "Demo Article", identifier: "demo://article/0",
            url: "https://example.com", date: .now, author: "Someone"
        )
        article.feed = feed
        article.tags = [tag]
        context.insert(article)
        try context.save()

        AppSettings().timelineAnchorIdentifier = "demo://article/0"

        LocalLibraryReset.wipe(context: context)

        #expect(try context.fetch(FetchDescriptor<Article>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Feed>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Tag>()).isEmpty)
        #expect(AppSettings().timelineAnchorIdentifier == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/LocalLibraryResetTests`
Expected: FAIL to build — `LocalLibraryReset` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```swift
// Yana/Utilities/LocalLibraryReset.swift
import Foundation
import SwiftData

/// Deletes every locally mirrored `Article`/`Feed`/`Tag` and clears the timeline anchor. Shared by
/// `UITestReset` (DEBUG, launch-argument-gated) and the demo-to-real-server pairing cleanup in
/// `OnboardingServerPage` (release-safe, flag-gated) — see
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md.
enum LocalLibraryReset {
    @MainActor
    static func wipe(context: ModelContext) {
        // Articles first: they reference feeds and tags.
        for article in (try? context.fetch(FetchDescriptor<Article>())) ?? [] { context.delete(article) }
        for feed in (try? context.fetch(FetchDescriptor<Feed>())) ?? [] { context.delete(feed) }
        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] { context.delete(tag) }
        do {
            try context.save()
        } catch {
            NSLog("LocalLibraryReset: save failed: \(error)")
        }
        // The anchor would now point at an article that no longer exists.
        AppSettings().timelineAnchorIdentifier = nil
    }
}
```

Update `Yana/Utilities/UITestReset.swift` to delegate to it:

```swift
#if DEBUG
import Foundation
import SwiftData

/// Wipes the local library so a UI test starts from a known-empty state. Triggered by the
/// `-UITEST_RESET_LIBRARY` launch argument.
///
/// Why this is needed: XCTest runs test classes alphabetically against **one** simulator app
/// container, so `ScreenshotUITests` runs before `YanaUITests` and seeds a full fixture library via
/// `ScreenshotSeed` — and that data survives into the next class, because `ScreenshotSeed` is
/// idempotent and bails as soon as any `Feed` exists. Any test asserting on the reader's empty
/// state (or on a short Settings form) therefore has to reset rather than assume a fresh container,
/// otherwise it passes alone and fails in a full run.
enum UITestReset {
    static let launchArgument = "-UITEST_RESET_LIBRARY"

    @MainActor
    static func resetIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        LocalLibraryReset.wipe(context: context)
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/LocalLibraryResetTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Utilities/LocalLibraryReset.swift Yana/Utilities/UITestReset.swift YanaTests/LocalLibraryResetTests.swift
git commit -m "Extract LocalLibraryReset from UITestReset"
```

---

### Task 2: Add `AppSettings` demo-mode flags and reset the banner dismissal on launch

**Files:**
- Modify: `Yana/Models/AppSettings.swift`
- Modify: `Yana/YanaApp.swift`
- Test: `YanaTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.hasSkippedServerPairing: Bool` (persisted, default `false`) — set by Task 5
  when the user skips pairing, read by Task 4 (`WelcomeGate`) and Tasks 7/8 (`DemoModeBanner` mount
  condition), cleared by Task 5's pairing-success cleanup.
- Produces: `AppSettings.hasDismissedDemoBanner: Bool` (persisted, default `false`) — set by Tasks
  7/8 when the banner's dismiss (×) is tapped, reset to `false` on every launch by `YanaApp`.

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/AppSettingsTests.swift` (inside the existing `AppSettingsTests` struct, alongside
`showUnreadBadgeDefaultsToFalse`/`showUnreadBadgeRoundTrips`):

```swift
    @Test func hasSkippedServerPairingDefaultsToFalseAndRoundTrips() {
        let settings = freshSettings()
        #expect(settings.hasSkippedServerPairing == false)
        settings.hasSkippedServerPairing = true
        #expect(settings.hasSkippedServerPairing == true)
    }

    @Test func hasDismissedDemoBannerDefaultsToFalseAndRoundTrips() {
        let settings = freshSettings()
        #expect(settings.hasDismissedDemoBanner == false)
        settings.hasDismissedDemoBanner = true
        #expect(settings.hasDismissedDemoBanner == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsTests`
Expected: FAIL to build — `hasSkippedServerPairing`/`hasDismissedDemoBanner` don't exist yet.

- [ ] **Step 3: Write minimal implementation**

In `Yana/Models/AppSettings.swift`, add to the `Key` enum (after the `hasCompletedOnboarding` line):

```swift
        // Onboarding
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        // Demo mode (skipped server pairing)
        static let hasSkippedServerPairing = "settings.hasSkippedServerPairing"
        static let hasDismissedDemoBanner = "settings.hasDismissedDemoBanner"
```

Add a new section after the existing `// MARK: Onboarding` property block:

```swift
    // MARK: Demo mode
    /// True when the user chose "Skip for now" on the onboarding server step instead of pairing.
    /// Cleared the moment a real pairing later succeeds (see `OnboardingServerPage`). Drives
    /// `WelcomeGate` (skip the re-pairing prompt) and `DemoModeBanner` (show the "you're viewing
    /// demo content" reminder).
    var hasSkippedServerPairing: Bool {
        get { access(keyPath: \.hasSkippedServerPairing); return defaults.bool(forKey: Key.hasSkippedServerPairing) }
        set { withMutation(keyPath: \.hasSkippedServerPairing) { defaults.set(newValue, forKey: Key.hasSkippedServerPairing) } }
    }
    /// Per-launch dismissal of `DemoModeBanner`. Not read at launch — `YanaApp` resets it to `false`
    /// on every launch — so the reminder reappears next time the app opens rather than being
    /// silenced forever.
    var hasDismissedDemoBanner: Bool {
        get { access(keyPath: \.hasDismissedDemoBanner); return defaults.bool(forKey: Key.hasDismissedDemoBanner) }
        set { withMutation(keyPath: \.hasDismissedDemoBanner) { defaults.set(newValue, forKey: Key.hasDismissedDemoBanner) } }
    }
```

In `Yana/YanaApp.swift`, in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, add the
reset as the first line of the method body, before the `#if DEBUG` block:

```swift
    @MainActor
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Demo-mode banner dismissal is per-launch, not permanent — see `AppSettings.hasDismissedDemoBanner`.
        AppSettings().hasDismissedDemoBanner = false
        #if DEBUG
        // Before any seeding: a UI test that asks for a clean library must not inherit fixture data
        // left behind by an earlier test class in the same simulator container.
        UITestReset.resetIfRequested(into: AppContainer.shared.mainContext)
        DebugSeed.seedIfRequested(into: AppContainer.shared.mainContext)
        Task { @MainActor in
            await ScreenshotSeed.seedIfRequested(into: AppContainer.shared.mainContext)
        }
        #endif
```

(The rest of the method is unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/AppSettingsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Yana/Models/AppSettings.swift Yana/YanaApp.swift YanaTests/AppSettingsTests.swift
git commit -m "Add AppSettings demo-mode flags"
```

---

### Task 3: Make `ScreenshotSeed` and its factories compile into release builds

**Files:**
- Modify: `Yana/Utilities/ScreenshotSeed.swift`
- Modify: `Yana/Utilities/ScreenshotImageFactory.swift`
- Modify: `Yana/Utilities/ScreenshotLogoFactory.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ScreenshotSeed.seed(into: ModelContext) async` (unchanged signature, already
  `@MainActor`) now callable from release-configuration code — Task 5's "Skip for now" button calls
  it directly.

This task only removes compiler gating; no logic changes. There is no new behavior to unit-test —
the existing `ScreenshotSeedTests.swift` (unchanged) is the regression check.

- [ ] **Step 1: Remove the `#if DEBUG`/`#endif` wrapper from all three files**

In `Yana/Utilities/ScreenshotSeed.swift`, delete the first line (`#if DEBUG`) and the last line
(`#endif`), and update the doc comment to reflect the new dual purpose:

```swift
import Foundation
import SwiftData

/// Curated, network-free demo library. Used two ways: (1) for App Store screenshots, gated by the
/// `-UITEST_SCREENSHOTS` launch argument via `seedIfRequested` so it never runs on a normal launch;
/// (2) as the seeded demo content shown to a user who skips server pairing during onboarding (see
/// `OnboardingServerPage`), which calls `seed(into:)` directly. Idempotent either way: bails if any
/// `Feed` already exists.
///
/// Authors a small library of fully ORIGINAL feeds/articles in-code (no third-party content,
/// no network) and generates every image in-process: `ScreenshotLogoFactory` for feed logos and
/// `ScreenshotImageFactory` for article lead images, both stored content-addressed via
/// `ImageStore` so the resulting `yana-img://<hash>` refs resolve like any real import.
enum ScreenshotSeed {
```

(Leave everything else in the file — the `feedSpecs` data, `seedIfRequested`, `seed(into:)` — exactly
as-is; only the `#if DEBUG` header/footer and this doc comment change.)

In `Yana/Utilities/ScreenshotImageFactory.swift`, delete the `#if DEBUG` first line and `#endif`
last line, leaving:

```swift
import UIKit

/// Generates fully-original, license-clean lead images for App Store screenshot fixtures.
/// Deterministic (same `index` always yields the same bytes) so the fixture is reproducible
/// and offline — no network fetch, no third-party imagery. Also used to generate demo-mode lead
/// images when onboarding's server step is skipped (see `ScreenshotSeed`).
enum ScreenshotImageFactory {
```

(rest of file unchanged).

In `Yana/Utilities/ScreenshotLogoFactory.swift`, delete the `#if DEBUG` first line and `#endif` last
line, leaving:

```swift
import UIKit

/// Generates fully-original, license-clean feed "logo" tiles for App Store screenshot
/// fixtures: a rounded-square tile in a given color with a bold white monogram centered
/// on it. Deterministic (same inputs always yield the same bytes) and network-free. Also used to
/// generate demo-mode feed logos when onboarding's server step is skipped (see `ScreenshotSeed`).
enum ScreenshotLogoFactory {
```

(rest of file unchanged).

- [ ] **Step 2: Run the existing screenshot-seed tests to confirm no regression**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ScreenshotSeedTests`
Expected: PASS (identical results to before this task — these files now compile without the DEBUG
gate, but their logic is untouched).

- [ ] **Step 3: Confirm the types compile in a Release configuration**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Release build`
Expected: BUILD SUCCEEDED. (This is the actual regression this task guards against: `UIGraphicsImageRenderer`/`CGGradient` usage in the two factories must compile outside DEBUG — it does, since none of it is DEBUG-only API.)

- [ ] **Step 4: Commit**

```bash
git add Yana/Utilities/ScreenshotSeed.swift Yana/Utilities/ScreenshotImageFactory.swift Yana/Utilities/ScreenshotLogoFactory.swift
git commit -m "Compile the screenshot demo-content library into release builds"
```

---

### Task 4: Teach `WelcomeGate` about a deliberate skip

**Files:**
- Modify: `Yana/Models/WelcomeGate.swift`
- Modify: `Yana/ContentView.swift`
- Modify: `Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift`
- Test: `YanaTests/WelcomeGateTests.swift` (new file — no existing tests for this type)

**Interfaces:**
- Produces: `WelcomeGate.neededStep(hasCompletedOnboarding: Bool, isPaired: Bool, hasSkippedServerPairing: Bool) -> WelcomeView.Step?`
  (added third parameter; both call sites updated in this task).

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/WelcomeGateTests.swift
import Testing
@testable import Yana

struct WelcomeGateTests {
    @Test func freshInstallNeedsWelcome() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: false, isPaired: false, hasSkippedServerPairing: false
        )
        #expect(step == .welcome)
    }

    @Test func revokedSessionNeedsServerStepEvenIfNeverSkippedBefore() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: false, hasSkippedServerPairing: false
        )
        #expect(step == .server)
    }

    @Test func deliberateSkipDoesNotReenterTheServerStep() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: false, hasSkippedServerPairing: true
        )
        #expect(step == nil)
    }

    @Test func pairedDeviceNeedsNoStep() {
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: true, hasSkippedServerPairing: false
        )
        #expect(step == nil)
    }

    @Test func pairedDeviceNeedsNoStepEvenIfItHadPreviouslySkipped() {
        // Defensive: once paired, hasSkippedServerPairing is expected to be cleared (Task 5), but
        // isPaired alone must already be sufficient here regardless.
        let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: true, isPaired: true, hasSkippedServerPairing: true
        )
        #expect(step == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/WelcomeGateTests`
Expected: FAIL to build — `neededStep` doesn't take a `hasSkippedServerPairing` argument yet.

- [ ] **Step 3: Write minimal implementation**

Replace `Yana/Models/WelcomeGate.swift` in full:

```swift
import Foundation

/// Pure check for whether the Welcome/pairing flow needs to be presented, and at which step.
/// Shared by `ContentView` (initial launch) and the server-migration notice's dismiss handlers
/// (iOS `fullScreenCover` and `ServerMigrationNoticeWindowRoot` on Mac) so Welcome is never
/// evaluated/presented at the same time as the migration notice — see
/// docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md.
///
/// `hasSkippedServerPairing` distinguishes "chose demo mode on purpose" (see
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md) from "was paired and the session
/// was revoked" — only the latter forces the device back into the `.server` step on every launch.
enum WelcomeGate {
    static func neededStep(
        hasCompletedOnboarding: Bool,
        isPaired: Bool,
        hasSkippedServerPairing: Bool
    ) -> WelcomeView.Step? {
        if !hasCompletedOnboarding { return .welcome }
        if !isPaired && !hasSkippedServerPairing { return .server }
        return nil
    }
}
```

Update the call site in `Yana/ContentView.swift` (`presentWelcomeIfNeeded`):

```swift
    private func presentWelcomeIfNeeded() {
        guard !Self.skipOnboarding else { return }
        guard let step = WelcomeGate.neededStep(
            hasCompletedOnboarding: settings.hasCompletedOnboarding,
            isPaired: AuthenticatedClient.current() != nil,
            hasSkippedServerPairing: settings.hasSkippedServerPairing
        ) else { return }
        appState.welcomeInitialStep = step
        if isMac {
            openWindow(id: WindowID.welcome, value: true)
        } else {
            appState.showWelcome = true
        }
    }
```

Update the call site in `Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift`:

```swift
            if let step = WelcomeGate.neededStep(
                hasCompletedOnboarding: settings.hasCompletedOnboarding,
                isPaired: AuthenticatedClient.current() != nil,
                hasSkippedServerPairing: settings.hasSkippedServerPairing
            ) {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/WelcomeGateTests`
Expected: PASS

- [ ] **Step 5: Build the whole scheme to confirm both call sites compile**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/WelcomeGate.swift Yana/ContentView.swift Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift YanaTests/WelcomeGateTests.swift
git commit -m "Teach WelcomeGate to respect a deliberate skip of server pairing"
```

---

### Task 5: "Skip for now" on the onboarding server step, and demo cleanup on later pairing

**Files:**
- Modify: `Yana/Views/Onboarding/OnboardingServerPage.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ScreenshotSeed.seed(into: ModelContext) async` (Task 3), `AppSettings.hasSkippedServerPairing`
  (Task 2), `LocalLibraryReset.wipe(context: ModelContext)` (Task 1), `AppContainer.shared.mainContext`
  (existing, `Yana/YanaApp.swift`).
- Produces: no new public interface — this is the terminal consumer of the pieces above.

This task has no pure logic to unit-test (it's a SwiftUI view driving side effects); it's verified by
build + the manual check in Task 9. Localization is required by the Global Constraints section.

- [ ] **Step 1: Add the "Skip for now" button and its wiring**

Replace `Yana/Views/Onboarding/OnboardingServerPage.swift` in full:

```swift
import SwiftUI

/// Onboarding step 2: pair with a Yana Server. Reuses `DevicePairingView`'s WebView-based
/// sign-in flow (the same one Settings uses to re-pair) — this is just the entry point that
/// collects the server address and presents it as a sheet.
///
/// "Skip for now" is the alternative to pairing: it seeds the demo library (`ScreenshotSeed`,
/// see docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md) and marks the device as
/// demo-mode (`AppSettings.hasSkippedServerPairing`) instead. If the user pairs a real server
/// later — either by returning here via "Show Welcome Screen Again" or via `DemoModeBanner`'s
/// "Pair Now" — the demo library is wiped before the first real sync runs.
struct OnboardingServerPage: View {
    let onPaired: () -> Void

    @State private var settings = AppSettings()
    @State private var serverURLText = ""
    @State private var isPairing = false
    @State private var isSkipping = false

    var body: some View {
        Form {
            Section {
                TextField("https://your-server.example.com", text: $serverURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server Address")
            } footer: {
                Text("Yana needs a Yana Server to sign in and sync your feeds.")
            }

            Section {
                Button("Sign In") { isPairing = true }
                    .disabled(URL(string: serverURLText) == nil)
            }

            Section {
                Button("Skip for now", action: skipPairing)
                    .disabled(isSkipping)
                    .accessibilityIdentifier("onboardingSkipServerButton")
            } footer: {
                Text("You'll see demo content until you pair a server. Pair anytime from Settings.")
            }
        }
        .accessibilityIdentifier("onboardingServerScreen")
        .onAppear { serverURLText = settings.serverBaseURL }
        .sheet(isPresented: $isPairing) {
            if let url = URL(string: serverURLText) {
                DevicePairingView(
                    serverBaseURL: url,
                    onPaired: { token in
                        settings.serverBaseURL = serverURLText
                        KeychainService.saveDeviceToken(token)
                        isPairing = false
                        if settings.hasSkippedServerPairing {
                            LocalLibraryReset.wipe(context: AppContainer.shared.mainContext)
                            settings.hasSkippedServerPairing = false
                        }
                        onPaired()
                    },
                    onCancel: { isPairing = false }
                )
            }
        }
    }

    private func skipPairing() {
        isSkipping = true
        Task {
            await ScreenshotSeed.seed(into: AppContainer.shared.mainContext)
            settings.hasSkippedServerPairing = true
            isSkipping = false
            onPaired()
        }
    }
}

#Preview {
    OnboardingServerPage(onPaired: {})
}
```

- [ ] **Step 2: Add localized strings**

Add these two entries to `Yana/Resources/Localizable.xcstrings` (open it as JSON, add to the
top-level `"strings"` object — match the existing shape, e.g. the `"Sign In"` entry right next to
where this reads):

```json
    "Skip for now" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Vorerst überspringen"
          }
        }
      }
    },
    "You'll see demo content until you pair a server. Pair anytime from Settings." : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Bis du einen Server koppelst, siehst du Demo-Inhalte. Du kannst jederzeit über die Einstellungen koppeln."
          }
        }
      }
    },
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/Onboarding/OnboardingServerPage.swift Yana/Resources/Localizable.xcstrings
git commit -m "Add a Skip for now path on the onboarding server step"
```

---

### Task 6: `DemoModeBanner` view

**Files:**
- Create: `Yana/Views/DemoModeBanner.swift`
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces: `DemoModeBanner(onPairNow: () -> Void, onDismiss: () -> Void)` — a `View`. Mounted by
  Task 7 (iOS) and Task 8 (Mac).

This is a leaf presentational view (matches the codebase's existing convention of not unit-testing
leaf SwiftUI views, e.g. `WelcomeIntroPage`, `AboutSettingsSection`); it's verified visually once
mounted in Tasks 7–8 and checked manually in Task 9.

- [ ] **Step 1: Create the view**

```swift
// Yana/Views/DemoModeBanner.swift
import SwiftUI

/// Persistent reminder that the timeline is showing seeded demo content rather than a paired
/// server's real feeds — shown via `.safeAreaInset(edge: .top)` in both the iOS `ReaderScreen`
/// (`Yana/Reader/ReaderHostView.swift`) and the Mac `MacRootView` whenever
/// `AppSettings.hasSkippedServerPairing` is true. See
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md.
struct DemoModeBanner: View {
    var onPairNow: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're viewing demo content")
                    .font(.subheadline.weight(.semibold))
                Text("Pair a Yana Server to sync your real feeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Pair Now", action: onPairNow)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("demoModeBanner")
    }
}

#Preview {
    DemoModeBanner(onPairNow: {}, onDismiss: {})
}
```

- [ ] **Step 2: Add localized strings**

Add these entries to `Yana/Resources/Localizable.xcstrings`:

```json
    "You're viewing demo content" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Du siehst Demo-Inhalte"
          }
        }
      }
    },
    "Pair a Yana Server to sync your real feeds." : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Koppele einen Yana-Server, um deine echten Feeds zu synchronisieren."
          }
        }
      }
    },
    "Pair Now" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Jetzt koppeln"
          }
        }
      }
    },
    "Dismiss" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Ausblenden"
          }
        }
      }
    },
```

(Check first whether `"Dismiss"` already exists as a key elsewhere in the catalog — if it does, reuse
it and do not add a duplicate entry.)

- [ ] **Step 3: Build to confirm it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Yana/Views/DemoModeBanner.swift Yana/Resources/Localizable.xcstrings
git commit -m "Add DemoModeBanner view"
```

---

### Task 7: Mount the banner in the iOS reader

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift`

**Interfaces:**
- Consumes: `DemoModeBanner` (Task 6), `AppSettings.hasSkippedServerPairing`/`hasDismissedDemoBanner`
  (Task 2), `AppState.welcomeInitialStep`/`showWelcome` (existing, `Yana/Models/AppState.swift`).

- [ ] **Step 1: Add the mount point to `ReaderScreen`**

In `Yana/Reader/ReaderHostView.swift`, add a computed property near `aiReady` (just above `var body`):

```swift
    private var aiReady: Bool { AISummaryReadiness.isReady(mode: settings.aiMode) }

    private var showDemoBanner: Bool {
        settings.hasSkippedServerPairing && !settings.hasDismissedDemoBanner
    }
```

Then insert a `.safeAreaInset(edge: .top)` modifier right after the `Group { switch ... }` block
closes and before the first `.sheet(...)` modifier (i.e. immediately after the line
`.ignoresSafeArea()` / the `}` that closes `Group`, currently followed by
`.sheet(isPresented: $appState.showSettings, onDismiss: {`):

```swift
        .safeAreaInset(edge: .top) {
            if showDemoBanner {
                DemoModeBanner(
                    onPairNow: {
                        appState.welcomeInitialStep = .server
                        appState.showWelcome = true
                    },
                    onDismiss: { settings.hasDismissedDemoBanner = true }
                )
            }
        }
        .sheet(isPresented: $appState.showSettings, onDismiss: {
```

(The rest of `body` — the four `.sheet`s, `.toast`, `.onAppear`, `.onChange`s — is unchanged.)

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Visually verify in the Simulator**

Use the iOS Simulator tool: launch the app fresh (or pass `-UITEST_RESET_ONBOARDING`), go through
onboarding, tap "Skip for now" on the server step, finish onboarding, and confirm the banner appears
above the reader content with the two buttons. Tap "Pair Now" and confirm it reopens `WelcomeView` at
the server step. Tap dismiss (×) and confirm the banner disappears for the rest of the session.

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift
git commit -m "Show the demo-mode banner in the iOS reader"
```

---

### Task 8: Mount the banner in the Mac root window

**Files:**
- Modify: `Yana/Reader/Mac/MacRootView.swift`
- Modify: `Yana/ContentView.swift`

**Interfaces:**
- Consumes: `DemoModeBanner` (Task 6), `AppSettings.hasSkippedServerPairing`/`hasDismissedDemoBanner`
  (Task 2), `WindowID.welcome` (existing, `Yana/Reader/Mac/WindowID.swift`).
- Produces: `MacRootView(appState: AppState)` (new required parameter — was previously
  parameterless).

- [ ] **Step 1: Thread `appState` into `MacRootView`**

In `Yana/ContentView.swift`, change the Mac branch of `body`:

```swift
            if isMac {
                MacRootView(appState: appState)
            } else {
```

In `Yana/Reader/Mac/MacRootView.swift`, add the property (matching `MacSettingsWindow`'s existing
pattern) right after the `struct MacRootView: View {` line:

```swift
struct MacRootView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
```

- [ ] **Step 2: Add the mount point**

Add a computed property near the other `@State`/computed properties (e.g. right after
`isSelectedStarred`):

```swift
    private var showDemoBanner: Bool {
        settings.hasSkippedServerPairing && !settings.hasDismissedDemoBanner
    }
```

In `body`, add `.safeAreaInset(edge: .top)` on the `NavigationSplitView`, right after
`.accessibilityIdentifier("mac.window.root")` and before `.sheet(isPresented: $showingCreateFeed)`:

```swift
        .accessibilityIdentifier("mac.window.root")
        .safeAreaInset(edge: .top) {
            if showDemoBanner {
                DemoModeBanner(
                    onPairNow: {
                        appState.welcomeInitialStep = .server
                        openWindow(id: WindowID.welcome, value: true)
                    },
                    onDismiss: { settings.hasDismissedDemoBanner = true }
                )
            }
        }
        .sheet(isPresented: $showingCreateFeed) {
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (Mac Catalyst code compiles as part of the same scheme's source set even
when building for the iOS Simulator destination — this only checks compilation, not Catalyst
codesigning/run, which is a known blocked-in-automation limitation, see the Mac Catalyst gotchas in
project `CLAUDE.md`).

- [ ] **Step 4: Commit**

```bash
git add Yana/Reader/Mac/MacRootView.swift Yana/ContentView.swift
git commit -m "Show the demo-mode banner in the Mac root window"
```

---

### Task 9: End-to-end manual verification

**Files:** none (verification only).

- [ ] **Step 1: Full skip → demo → pair → cleanup flow, iOS Simulator**

Using the iOS Simulator tool:
1. Launch the app with a fresh library (e.g. `-UITEST_RESET_ONBOARDING -UITEST_RESET_LIBRARY`, or a
   fresh simulator).
2. Go through onboarding to the server step; tap "Skip for now".
3. Confirm: onboarding advances to the AI-mode step, then Finish lands on the reader with seeded
   demo articles visible (feeds/articles from `ScreenshotSeed.feedSpecs`) and the `DemoModeBanner`
   showing above the content.
4. Quit and relaunch the app. Confirm the banner still shows (dismissal doesn't persist across
   launches) and no re-pairing prompt appears (the `.server` onboarding step is not force-shown).
5. Dismiss the banner (×); confirm it disappears for the rest of this session.
6. Tap "Pair Now" (reopen the banner first by relaunching if needed); confirm it reopens onboarding
   at the server step.
7. Pair against a real (or test) Yana Server. Confirm: the demo feeds/articles are gone, the banner
   no longer shows, and real synced content appears once the server responds.

- [ ] **Step 2: Record the result**

If any step fails, fix the underlying task before proceeding — do not mark this plan complete with a
known-failing manual check. Once all steps pass, note in the PR/commit description which steps were
manually verified (Mac Catalyst run/verification is out of scope for this plan per the Mac Catalyst
codesigning-blocked-in-automation limitation — Task 8's build-only check is the extent of Mac
coverage here).
