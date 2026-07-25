# macOS App Store Screenshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate reproducible, offline Mac App Store screenshots (4 shots × en-US/de-DE, 2880×1800) for the Mac Catalyst build via a new `fastlane screenshots_mac` lane.

**Architecture:** A Catalyst XCUITest navigates the Mac UI and attaches window captures as `XCTAttachment`s; the fastlane lane exports them from the `.xcresult` with `xcresulttool export attachments`, then a CoreGraphics script composites the Settings-window shots over the main-window capture at exactly 2880×1800. The existing `ScreenshotSeed` offline fixture is reused unchanged.

**Tech Stack:** Swift 6, XCUITest, Mac Catalyst, fastlane (Ruby), CoreGraphics, `xcresulttool`, XcodeGen.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-07-25-macos-screenshots-design.md`. Read it before starting.
- Output size is exactly **2880×1800 px** (1440×900pt at 2x). The compositor asserts this.
- Shot keys are exactly `01_Reader`, `02_Search`, `03_Feeds`, `04_AI`. Keep them in sync across the test, the lane, and CLAUDE.md.
- Output lands in `fastlane/screenshots_mac/{en-US,de-DE}/` — **never** inside `fastlane/screenshots/`, because the iOS lane's `frame_screenshots` scans that directory and has no Mac frames.
- Locales: `en-US` and `de-DE` only.
- **No new user-facing strings.** Everything added is DEBUG- or test-only, so `Yana/Resources/Localizable.xcstrings` must not change. If a task seems to need a new visible string, stop and reconsider.
- Swift 6 strict concurrency: annotate `@MainActor` where UIKit/SwiftUI state is touched, matching the surrounding code.
- No Homebrew/gem dependencies beyond what the repo already requires (Xcode, XcodeGen, fastlane). The compositor uses CoreGraphics via `xcrun swift`; `sips` cannot composite and ImageMagick/Pillow are forbidden.
- Run `xcodegen generate` after any `project.yml` change.
- Commit after each task.

**ENVIRONMENT CONSTRAINT (added during execution).** Mac Catalyst requires a real signing
identity, and the login keychain is locked to the automation shell (`codesign` fails with
`errSecInternalComponent`, `security`: "User interaction is not allowed"). Therefore:

- Catalyst **builds** must be verified with `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO` appended to the `xcodebuild` invocation. This proves compile + link,
  which is what these tasks can prove.
- Catalyst **runs** (the UI test, the lane) cannot be executed here. Steps marked
  **[DEFERRED — USER RUNS]** below are handed to the user to run in an interactive session with an
  unlocked keychain. Do not fake their output, and do not mark a task complete by claiming a
  deferred step passed.
- iOS Simulator builds and tests are unaffected (ad-hoc signing) and must still be run.

---

### Task 1: Make the test bundles build for Mac Catalyst

`xcodebuild` builds **every** test target in the `Yana` scheme even when `-only-testing` narrows execution, so both test targets need Catalyst support before any Mac test can run.

**Files:**
- Modify: `project.yml` (the `YanaTests` and `YanaUITests` target `settings.base` blocks)

**Interfaces:**
- Consumes: nothing.
- Produces: a project where `xcodebuild build-for-testing -destination 'platform=macOS,variant=Mac Catalyst'` succeeds. Every later task depends on this.

- [ ] **Step 1: Confirm the Catalyst test build currently fails**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcodebuild build-for-testing -scheme Yana \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -20
```

Expected: FAILURE. The test targets are iOS-only, so expect a message about the target not supporting the Mac Catalyst destination (wording varies by Xcode; any failure mentioning the destination or platform is the expected state).

- [ ] **Step 2: Add Catalyst settings to both test targets**

In `project.yml`, the `YanaTests` target's `settings.base` currently reads:

```yaml
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.fa-krug.Yana.tests
        GENERATE_INFOPLIST_FILE: true
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Yana.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Yana"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

Replace it with:

```yaml
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.fa-krug.Yana.tests
        GENERATE_INFOPLIST_FILE: true
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Yana.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Yana"
        BUNDLE_LOADER: "$(TEST_HOST)"
        # The Mac screenshot lane runs `xcodebuild test` against a Mac Catalyst destination,
        # and xcodebuild builds every test target in the scheme even with -only-testing. So
        # both test bundles must support Catalyst, not just the UI-test one.
        SUPPORTS_MACCATALYST: true
        TARGETED_DEVICE_FAMILY: "1,2,6"
        DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: false
```

And the `YanaUITests` target's `settings.base` currently reads:

```yaml
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.fa-krug.Yana.uitests
        GENERATE_INFOPLIST_FILE: true
```

Replace it with:

```yaml
      base:
        PRODUCT_BUNDLE_IDENTIFIER: de.fa-krug.Yana.uitests
        GENERATE_INFOPLIST_FILE: true
        SUPPORTS_MACCATALYST: true
        TARGETED_DEVICE_FAMILY: "1,2,6"
        DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: false
```

- [ ] **Step 3: Regenerate the project**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios && xcodegen generate
```
Expected: `Created project at /Users/skrug/PycharmProjects/yana-ios/Yana.xcodeproj`

- [ ] **Step 4: Verify the Catalyst test build now succeeds**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcodebuild build-for-testing -scheme Yana \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -20
```
Expected: `** TEST BUILD SUCCEEDED **`

If it fails with compile errors in `YanaTests`/`YanaUITests` (rather than a destination error), the offending code uses an API unavailable on Catalyst. Guard just that code with `#if !targetEnvironment(macCatalyst)` and note it in the commit message. Do **not** delete tests.

- [ ] **Step 5: Verify the iOS test build still works**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcodebuild build-for-testing -scheme Yana \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **` — the Catalyst additions must not regress iOS.

- [ ] **Step 6: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
git add project.yml
git commit -m "Let test bundles build for Mac Catalyst

xcodebuild builds every test target in the scheme even with
-only-testing, so the Mac screenshot lane needs both YanaTests and
YanaUITests to support the Catalyst destination."
```

---

### Task 2: Deterministic Mac window geometry and a quiet launch

The captures must be exactly 1440×900pt regardless of host machine, and nothing asynchronous (launch refresh spinner, iCloud pull, error toast) may leak into a shot.

**Files:**
- Create: `Yana/Utilities/MacScreenshotWindow.swift`
- Create: `YanaTests/MacScreenshotWindowTests.swift`
- Modify: `Yana/YanaApp.swift` (the `#if targetEnvironment(macCatalyst)` block at lines 139-143)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `MacScreenshotWindow.launchArgument: String` == `"-UITEST_MAC_SCREENSHOTS"`
  - `MacScreenshotWindow.sizeArgument: String` == `"-UITEST_MAC_WINDOW_SIZE"`
  - `MacScreenshotWindow.defaultSize: CGSize` == `CGSize(width: 1440, height: 900)`
  - `MacScreenshotWindow.isRequested: Bool`
  - `static func size(from arguments: [String]) -> CGSize` — pure, testable on every platform
  - `@MainActor static func applyWindowGeometryIfRequested()` — pins the main window's size
  - `@MainActor static func quietBackgroundWorkIfRequested()` — forces iCloud sync off

  Both are called from `MacRootView.onAppear` in Task 3. They are deliberately **two** functions:
  pinning geometry and silencing background work are unrelated jobs, and folding the settings
  mutation into a geometry-named function would hide a side effect behind a misleading name.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/MacScreenshotWindowTests.swift`:

```swift
#if DEBUG
import CoreGraphics
import Testing

@testable import Yana

@MainActor
struct MacScreenshotWindowTests {
    @Test func defaultsWhenNoOverridePresent() {
        let size = MacScreenshotWindow.size(from: ["-UITEST_MAC_SCREENSHOTS"])
        #expect(size == MacScreenshotWindow.defaultSize)
    }

    @Test func parsesExplicitOverride() {
        let size = MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "1280x800"])
        #expect(size == CGSize(width: 1280, height: 800))
    }

    @Test func ignoresMalformedOverride() {
        // A garbled value must fall back rather than produce a zero-sized window.
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "wide"])
                == MacScreenshotWindow.defaultSize)
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "1440x"])
                == MacScreenshotWindow.defaultSize)
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "0x0"])
                == MacScreenshotWindow.defaultSize)
    }

    @Test func ignoresOverrideWithNoValueFollowing() {
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE"])
                == MacScreenshotWindow.defaultSize)
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcodebuild test -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:YanaTests/MacScreenshotWindowTests 2>&1 | tail -20
```
Expected: FAIL — compile error, `cannot find 'MacScreenshotWindow' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Yana/Utilities/MacScreenshotWindow.swift`:

```swift
#if DEBUG
import CoreGraphics
import Foundation
import UIKit

/// Forces the Mac window into a fixed size so App Store captures are byte-for-byte reproducible
/// across machines, and silences the asynchronous work that would otherwise bleed into a shot.
///
/// Gated by the `-UITEST_MAC_SCREENSHOTS` launch argument (set only by `MacScreenshotUITests`), so
/// a normal launch is untouched. The default 1440x900pt renders as exactly 2880x1800px on a 2x
/// display — the largest Mac App Store screenshot size.
enum MacScreenshotWindow {
    static let launchArgument = "-UITEST_MAC_SCREENSHOTS"
    static let sizeArgument = "-UITEST_MAC_WINDOW_SIZE"
    static let defaultSize = CGSize(width: 1440, height: 900)

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Parses an optional `-UITEST_MAC_WINDOW_SIZE 1440x900` override, falling back to
    /// `defaultSize` for anything missing, malformed, or non-positive. Pure so it is testable on
    /// every platform (the geometry call below is Catalyst-only, this is not).
    static func size(from arguments: [String]) -> CGSize {
        guard let flagIndex = arguments.firstIndex(of: sizeArgument),
              case let valueIndex = flagIndex + 1,
              valueIndex < arguments.count
        else { return defaultSize }

        let parts = arguments[valueIndex].split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return defaultSize }

        return CGSize(width: width, height: height)
    }

    /// Silence work that would otherwise land in a captured frame.
    ///
    /// The app under test shares the real `de.fa-krug.Yana` container, so a developer's persisted
    /// "iCloud sync on" would pull their actual feeds mid-capture and destroy determinism. Writing
    /// to the shared container is deliberate: the run also wipes the library via
    /// `-UITEST_RESET_LIBRARY`, so this is already a throwaway state.
    @MainActor
    static func quietBackgroundWorkIfRequested() {
        guard isRequested else { return }
        AppSettings().iCloudSyncEnabled = false
    }

    /// Pin the main window to the target size. Call from the Mac root view's `onAppear` — it must
    /// run against the MAIN window's scene only, never the Settings window's.
    @MainActor
    static func applyWindowGeometryIfRequested() {
        guard isRequested else { return }

        #if targetEnvironment(macCatalyst)
        let target = size(from: ProcessInfo.processInfo.arguments)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        // Clamping min == max is what actually forces the size: requestGeometryUpdate alone is a
        // request the window server may round or refuse, and MacRootView's sidebar minimum would
        // otherwise let the window settle at a different width. Relax the restrictions afterwards
        // so the window is still a normal, resizable window for anyone watching the run.
        scene.sizeRestrictions?.minimumSize = target
        scene.sizeRestrictions?.maximumSize = target
        scene.requestGeometryUpdate(.Mac(sizeRestrictions: nil)) { _ in }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            scene.sizeRestrictions?.minimumSize = CGSize(width: 800, height: 600)
            scene.sizeRestrictions?.maximumSize = CGSize(width: .greatestFiniteMagnitude,
                                                         height: .greatestFiniteMagnitude)
        }
        #endif
    }
}
#endif
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios && xcodegen generate && \
xcodebuild test -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:YanaTests/MacScreenshotWindowTests 2>&1 | tail -20
```
Expected: PASS, 4 tests.

Note: `xcodebuild` prints `Executed 1 test` for the XCTest UI-test shim; Swift Testing reports its own count separately. Look for the Swift Testing summary line.

- [ ] **Step 5: Suppress the Mac launch refresh under the screenshot arg**

In `Yana/YanaApp.swift`, the scene `.task` currently ends with (lines 139-143):

```swift
                    #if targetEnvironment(macCatalyst)
                    // Kick the Mac's launch refresh now that the window is up — deferred so it
                    // doesn't contend with cold-start rendering (see `scheduleLaunchRefresh`).
                    appDelegate.scheduleLaunchRefresh()
                    #endif
```

Replace with:

```swift
                    #if targetEnvironment(macCatalyst)
                    // Kick the Mac's launch refresh now that the window is up — deferred so it
                    // doesn't contend with cold-start rendering (see `scheduleLaunchRefresh`).
                    // Skipped for screenshot capture: a real fetch would spin the toolbar
                    // progress view and can raise an error toast, both of which would land in
                    // the captured frame.
                    var skipLaunchRefresh = false
                    #if DEBUG
                    skipLaunchRefresh = MacScreenshotWindow.isRequested
                    #endif
                    if !skipLaunchRefresh { appDelegate.scheduleLaunchRefresh() }
                    #endif
```

- [ ] **Step 6: Verify the whole app still builds for both platforms**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcodebuild build -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5
xcodebuild build -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
git add Yana/Utilities/MacScreenshotWindow.swift YanaTests/MacScreenshotWindowTests.swift Yana/YanaApp.swift
git commit -m "Pin Mac window size and quiet the launch for screenshots

Captures must be exactly 1440x900pt (2880x1800 at 2x) on any machine.
Also forces iCloud sync off, since the app under test shares the real
container and a developer's synced feeds would break determinism."
```

---

### Task 3: Accessibility identifiers for Mac navigation

The Mac UI has none today, and EN/DE labels differ, so the test needs locale-independent targets.

**Files:**
- Modify: `Yana/Reader/Mac/MacRootView.swift` (root `NavigationSplitView` at lines 23-49; sidebar `List` at lines 186-193)
- Modify: `Yana/Reader/Mac/MacSettingsWindow.swift` (pane `List` at lines 15-19; root at lines 14-29)

**Interfaces:**
- Consumes: `MacScreenshotWindow.applyWindowGeometryIfRequested()` and
  `MacScreenshotWindow.quietBackgroundWorkIfRequested()` from Task 2.
- Produces these identifiers, consumed by Task 4:
  - `mac.window.root` — main window root
  - `mac.sidebar.list` — the article list
  - `mac.settings.window` — Settings window root
  - `mac.settings.pane.general` / `.reader` / `.feeds` / `.tags` / `.integrations` / `.ai` / `.about`

  The sidebar **search field has no identifier** — `.searchable` does not forward one reliably. Task 4 targets it as `app.searchFields.firstMatch`, which is already locale-independent.

- [ ] **Step 1: Add identifiers to the main window**

In `Yana/Reader/Mac/MacRootView.swift`, the sidebar `List` modifier chain begins (lines 193-199):

```swift
        .listStyle(.sidebar)
```

Insert an identifier immediately before `.listStyle(.sidebar)`:

```swift
        // Screenshot/UI-test navigation target. EN/DE labels differ, so tests key off identifiers.
        .accessibilityIdentifier("mac.sidebar.list")
        .listStyle(.sidebar)
```

Then in the same file, the root `NavigationSplitView` closes with `.toast($model.toast)` (line 33). Change:

```swift
        .toast($model.toast)
```

to:

```swift
        .accessibilityIdentifier("mac.window.root")
        .toast($model.toast)
```

And extend the existing `.onAppear` (lines 38-41) from:

```swift
        .onAppear {
            model.configure(modelContext: modelContext, store: store)
            model.applyTimeline()
        }
```

to:

```swift
        .onAppear {
            model.configure(modelContext: modelContext, store: store)
            model.applyTimeline()
            #if DEBUG
            // Pin the window to a fixed size when capturing App Store screenshots. Main window
            // only — the Settings window is captured at its natural size and composited.
            // (`quietBackgroundWorkIfRequested()` is NOT called here: it already runs from
            // AppDelegate.didFinishLaunching, which is the only point guaranteed to precede
            // ConfigSyncService.start().)
            MacScreenshotWindow.applyWindowGeometryIfRequested()
            #endif
        }
```

- [ ] **Step 2: Add identifiers to the Settings window**

In `Yana/Reader/Mac/MacSettingsWindow.swift`, the pane list currently reads (lines 14-21):

```swift
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Settings")
```

Replace with:

```swift
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                        // Screenshot/UI-test navigation target — pane titles are localized, the
                        // raw value is not.
                        .accessibilityIdentifier("mac.settings.pane.\(pane.rawValue)")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Settings")
```

Then change the root modifier chain (lines 26-28) from:

```swift
        .toggleStyle(.switch)
        .frame(minWidth: 700, minHeight: 560)
```

to:

```swift
        .toggleStyle(.switch)
        .accessibilityIdentifier("mac.settings.window")
        .frame(minWidth: 700, minHeight: 560)
```

- [ ] **Step 3: Verify it builds**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcodebuild build -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Confirm no new strings were introduced**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios && git diff --stat Yana/Resources/Localizable.xcstrings
```
Expected: **empty output.** Accessibility identifiers are not user-facing and must never be localized. If the catalog changed, revert it.

- [ ] **Step 5: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
git add Yana/Reader/Mac/MacRootView.swift Yana/Reader/Mac/MacSettingsWindow.swift
git commit -m "Add accessibility identifiers to the Mac surfaces

The Mac window and Settings panes had none, so a screenshot test had
nothing locale-independent to navigate by. Also wires the main window's
onAppear to the screenshot geometry hook."
```

---

### Task 4: The Catalyst screenshot test

**Files:**
- Create: `YanaUITests/MacScreenshotUITests.swift`

**Interfaces:**
- Consumes: identifiers from Task 3; `-UITEST_MAC_SCREENSHOTS` from Task 2; `-UITEST_SCREENSHOTS` (`ScreenshotSeed.launchArgument`) and `-UITEST_RESET_LIBRARY` (`UITestReset.launchArgument`), both pre-existing.
- Produces: two test methods the lane selects with `-only-testing:`
  - `YanaUITests/MacScreenshotUITests/testCaptureScreenshotsEnglish`
  - `YanaUITests/MacScreenshotUITests/testCaptureScreenshotsGerman`

  and four attachments per run, named exactly `01_Reader.png`, `02_Search.png`, `03_Feeds.overlay.png`, `04_AI.overlay.png`.

- [ ] **Step 1: Write the test**

Create `YanaUITests/MacScreenshotUITests.swift`:

```swift
#if targetEnvironment(macCatalyst)
import XCTest

/// Captures Mac App Store screenshots from the Mac Catalyst build.
///
/// This deliberately does NOT use fastlane's SnapshotHelper: `capture_screenshots` drives iOS
/// Simulator destinations only, and frameit has no Mac device frames. Instead each shot is an
/// `XCTAttachment`, which the `screenshots_mac` lane exports from the .xcresult with
/// `xcresulttool export attachments`. Attachments are the only sandbox-safe channel here — the
/// Catalyst test runner cannot write outside its own container.
final class MacScreenshotUITests: XCTestCase {
    /// Async feed logos have no cache (`FeedLogoView` refetches per view), so every shot that
    /// shows one needs a settle beat or the logo renders as the globe placeholder.
    private static let logoSettle: TimeInterval = 2.0

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureScreenshotsEnglish() throws {
        try capture(languageCode: "en", localeIdentifier: "en_US")
    }

    @MainActor
    func testCaptureScreenshotsGerman() throws {
        try capture(languageCode: "de", localeIdentifier: "de_DE")
    }

    // MARK: - Flow

    @MainActor
    private func capture(languageCode: String, localeIdentifier: String) throws {
        let app = XCUIApplication()
        app.launchArguments += [
            // Wipe first, then seed: YanaApp runs UITestReset before ScreenshotSeed, and the
            // seed's "bail if any Feed exists" guard only passes because reset just emptied
            // the store. Together these replace the iOS lane's erase_simulator.
            "-UITEST_RESET_LIBRARY",
            "-UITEST_SCREENSHOTS",
            // Pin the window to 1440x900pt and suppress the launch refresh.
            "-UITEST_MAC_SCREENSHOTS",
            // Force the app locale; there is no simulator language setting to lean on.
            "-AppleLanguages", "(\(languageCode))",
            "-AppleLocale", localeIdentifier,
        ]
        app.launch()

        // Shot 1 — main window: sidebar + the hero article the seed parked the anchor on.
        let sidebar = app.descendants(matching: .any).matching(identifier: "mac.sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 60),
                      "Mac sidebar never appeared — seeding may have failed")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 60),
                      "sidebar rendered no article rows")
        Thread.sleep(forTimeInterval: Self.logoSettle)
        let mainWindow = app.windows.firstMatch
        attach(mainWindow.screenshot(), named: "01_Reader.png")

        // Shot 2 — search. The field is matched by element type, not identifier: `.searchable`
        // does not forward an accessibilityIdentifier reliably, and searchFields is already
        // locale-independent.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "sidebar search field missing")
        search.click()
        search.typeText("battery")
        // 250ms debounce in MacSidebarView, plus the predicate fetch.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 15),
                      "search for \"battery\" produced no rows")
        Thread.sleep(forTimeInterval: Self.logoSettle)
        attach(app.windows.firstMatch.screenshot(), named: "02_Search.png")

        // Clear the query so the Settings shots composite over an unfiltered timeline.
        search.buttons.firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.0)

        // Shots 3 and 4 — the Settings window, captured at its natural size. The lane composites
        // these over 01_Reader. Capturing the main window while Settings floats over it risks the
        // occluding window bleeding in, which is why 01_Reader is reused as the base.
        let settingsWindow = try openSettings(in: app)

        try selectPane("feeds", in: app)
        Thread.sleep(forTimeInterval: Self.logoSettle)
        attach(settingsWindow.screenshot(), named: "03_Feeds.overlay.png")

        try selectPane("ai", in: app)
        Thread.sleep(forTimeInterval: 1.0)
        attach(settingsWindow.screenshot(), named: "04_AI.overlay.png")
    }

    // MARK: - Navigation

    /// Open Settings with ⌘, falling back to the toolbar overflow menu.
    @MainActor
    private func openSettings(in app: XCUIApplication) throws -> XCUIElement {
        let window = app.descendants(matching: .any)
            .matching(identifier: "mac.settings.window").firstMatch

        app.typeKey(",", modifierFlags: .command)
        if window.waitForExistence(timeout: 10) { return window }

        // Fallback: the ellipsis button in MacRootView's .primaryAction toolbar group. It has no
        // identifier, so match the SF Symbol image name XCUITest exposes as the label.
        let overflow = app.buttons["ellipsis.circle"].exists
            ? app.buttons["ellipsis.circle"]
            : app.toolbars.buttons.element(boundBy: app.toolbars.buttons.count - 1)
        XCTAssertTrue(overflow.waitForExistence(timeout: 10),
                      "neither ⌘, nor the toolbar overflow could open Settings")
        overflow.click()
        let item = app.menuItems.matching(NSPredicate(format: "label IN %@",
                                                     ["Settings", "Einstellungen"])).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Settings menu item missing")
        item.click()

        XCTAssertTrue(window.waitForExistence(timeout: 15), "Settings window never appeared")
        return window
    }

    /// Click a Settings sidebar pane by its `SettingsPane` raw value.
    @MainActor
    private func selectPane(_ rawValue: String, in app: XCUIApplication) throws {
        let row = app.descendants(matching: .any)
            .matching(identifier: "mac.settings.pane.\(rawValue)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Settings pane \"\(rawValue)\" missing")
        row.click()
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - Attachments

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        // Without .keepAlways the attachment is discarded on success — which is every run we
        // actually want the images from.
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcodebuild build-for-testing -scheme Yana \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -10
```
Expected: `** TEST BUILD SUCCEEDED **`

- [ ] **Step 3: [DEFERRED — USER RUNS] Run the English pass and confirm attachments land**

Requires an unlocked keychain. Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
rm -rf /tmp/yana-mac.xcresult
xcodebuild test -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:YanaUITests/MacScreenshotUITests/testCaptureScreenshotsEnglish \
  -resultBundlePath /tmp/yana-mac.xcresult 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

Then:
```bash
rm -rf /tmp/yana-att && \
xcrun xcresulttool export attachments --path /tmp/yana-mac.xcresult \
  --output-path /tmp/yana-att && \
python3 -c "
import json
m=json.load(open('/tmp/yana-att/manifest.json'))
for t in m:
    for a in t.get('attachments',[]):
        print(a.get('suggestedHumanReadableName'), '->', a.get('exportedFileName'))
"
```
Expected: four lines naming `01_Reader.png`, `02_Search.png`, `03_Feeds.overlay.png`, `04_AI.overlay.png`.

- [ ] **Step 4: [DEFERRED — USER RUNS] Confirm the main-window capture is 2880×1800**

Run:
```bash
cd /tmp/yana-att && for f in *.png; do echo -n "$f: "; sips -g pixelWidth -g pixelHeight "$f" | tr '\n' ' '; echo; done
```
Expected: the `01_Reader`/`02_Search` exports report `pixelWidth: 2880` and `pixelHeight: 1800`. The two overlays are smaller (the Settings window at its natural size) — that is correct.

If the main window is **not** 2880×1800, the geometry clamp in Task 2 did not take. Do not proceed — fix it first, since the compositor asserts the final size.

- [ ] **Step 5: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
git add YanaUITests/MacScreenshotUITests.swift
git commit -m "Add Mac Catalyst screenshot UI test

Captures four shots per locale as XCTAttachments. fastlane's snapshot
can't target macOS and the Catalyst runner is sandboxed, so
attachments plus xcresulttool export are the way out."
```

---

### Task 5: The compositor

**Files:**
- Create: `fastlane/mac_composite.swift`

**Interfaces:**
- Consumes: a base PNG (2880×1800 or otherwise) and an overlay PNG from Task 4.
- Produces a CLI contract used by Task 6:
  `xcrun swift fastlane/mac_composite.swift <base.png> <overlay.png> <out.png>`
  Exits 0 on success having written a 2880×1800 PNG; exits 1 with a message on stderr otherwise.

- [ ] **Step 1: Write the script**

Create `fastlane/mac_composite.swift`:

```swift
#!/usr/bin/env swift
//
// Composites a Mac Settings-window capture over the main-window capture and writes a PNG at
// exactly the Mac App Store's 2880x1800.
//
// Usage: xcrun swift fastlane/mac_composite.swift <base.png> <overlay.png> <out.png>
//
// CoreGraphics only, on purpose: `sips` cannot composite, and ImageMagick/Pillow would add a
// Homebrew/pip dependency the repo does not otherwise need.

import AppKit
import CoreGraphics
import Foundation

let canvas = CGSize(width: 2880, height: 1800)
/// Fraction of canvas width the overlay window occupies. The Settings window is 720pt wide
/// against a 1440pt main window, so half — preserved here so the composite matches what the user
/// would actually see.
let overlayWidthFraction: CGFloat = 0.5

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mac_composite: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3 else {
    fail("usage: mac_composite.swift <base.png> <overlay.png> <out.png>")
}
let (basePath, overlayPath, outPath) = (args[0], args[1], args[2])

func loadImage(_ path: String) -> CGImage {
    guard let data = FileManager.default.contents(atPath: path) as CFData?,
          let source = CGImageSourceCreateWithData(data, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("could not read image at \(path)") }
    return image
}

let base = loadImage(basePath)
let overlay = loadImage(overlayPath)

guard let context = CGContext(
    data: nil,
    width: Int(canvas.width),
    height: Int(canvas.height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("could not create the drawing context") }

context.interpolationQuality = .high

// Base fills the canvas. Scaling here is what makes a non-Retina host still produce a valid
// (if upscaled) App Store image instead of a wrong-sized one.
context.draw(base, in: CGRect(origin: .zero, size: canvas))

// Overlay, centred, scaled to a fixed fraction of the canvas so both Settings shots line up
// even if the window's natural height differs between panes.
let overlayWidth = canvas.width * overlayWidthFraction
let overlayScale = overlayWidth / CGFloat(overlay.width)
let overlaySize = CGSize(width: overlayWidth, height: CGFloat(overlay.height) * overlayScale)
let overlayRect = CGRect(
    x: (canvas.width - overlaySize.width) / 2,
    y: (canvas.height - overlaySize.height) / 2,
    width: overlaySize.width,
    height: overlaySize.height
)

// Drop shadow so the floating window reads as floating rather than pasted on.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18),
                  blur: 48,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
context.draw(overlay, in: overlayRect)
context.restoreGState()

guard let output = context.makeImage() else { fail("could not render the composite") }
guard output.width == Int(canvas.width), output.height == Int(canvas.height) else {
    fail("composite is \(output.width)x\(output.height), expected 2880x1800")
}

let outURL = URL(fileURLWithPath: outPath)
guard let destination = CGImageDestinationCreateWithURL(
    outURL as CFURL, "public.png" as CFString, 1, nil
) else { fail("could not create the output destination at \(outPath)") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(outPath)") }
```

- [ ] **Step 2: Verify it rejects bad input**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios && xcrun swift fastlane/mac_composite.swift; echo "exit=$?"
```
Expected: `mac_composite: usage: ...` on stderr and `exit=1`.

- [ ] **Step 3: Verify it produces an exactly-sized composite**

Real captures are unavailable here (see the environment constraint), so verify against **synthetic
inputs at the exact sizes the real pipeline produces**: a 2880×1800 base and a 1440×1240 overlay
(the Settings window's 720×620 at 2x). This exercises every code path the real run does — decode,
scale, shadow, size assert, encode.

```bash
cd /Users/skrug/PycharmProjects/yana-ios
python3 - <<'PY'
import subprocess
# Solid-colour PNGs at the two real sizes, built with sips from a scratch TIFF.
for name, w, h, colour in [("base", 2880, 1800, "0000FF"), ("overlay", 1440, 1240, "FF0000")]:
    subprocess.run(["python3", "-c", f'''
import struct, zlib
w, h = {w}, {h}
rgb = bytes.fromhex("{colour}")
raw = b"".join(b"\\x00" + rgb * w for _ in range(h))
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
png = (b"\\x89PNG\\r\\n\\x1a\\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw))
       + chunk(b"IEND", b""))
open("/tmp/{name}.png", "wb").write(png)
'''], check=True)
    print(f"/tmp/{name}.png {w}x{h}")
PY
xcrun swift fastlane/mac_composite.swift /tmp/base.png /tmp/overlay.png /tmp/composite-test.png
echo "exit=$?"
sips -g pixelWidth -g pixelHeight /tmp/composite-test.png
```

Expected: `exit=0`, then `pixelWidth: 2880` and `pixelHeight: 1800`.

Also verify the size assert actually fires — feed it a base that is not 2880×1800 and confirm the
output is still exactly 2880×1800 (the base is scaled to fill, so this must still succeed):

```bash
cd /Users/skrug/PycharmProjects/yana-ios
xcrun swift fastlane/mac_composite.swift /tmp/overlay.png /tmp/overlay.png /tmp/composite-odd.png
echo "exit=$?" && sips -g pixelWidth -g pixelHeight /tmp/composite-odd.png
```

Expected: `exit=0`, `pixelWidth: 2880`, `pixelHeight: 1800`.
Expected: `exit=0`, then `pixelWidth: 2880` and `pixelHeight: 1800`.

- [ ] **Step 4: Verify the overlay landed centred and scaled**

Solid colours make this checkable without eyeballing: sample the centre pixel (must be overlay
red), a corner (must be base blue), and confirm the overlay occupies half the canvas width.

```bash
cd /Users/skrug/PycharmProjects/yana-ios
cat > /tmp/probe.swift <<'SWIFT'
import CoreGraphics
import Foundation
let path = CommandLine.arguments[1]
let data = FileManager.default.contents(atPath: path)! as CFData
let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data, nil)!, 0, nil)!
var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8,
                    bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
func at(_ x: Int, _ y: Int) -> String {
    let i = (y * img.width + x) * 4
    return String(format: "%02X%02X%02X", px[i], px[i+1], px[i+2])
}
print("size=\(img.width)x\(img.height) centre=\(at(img.width/2, img.height/2)) corner=\(at(4, 4))")
SWIFT
xcrun swift /tmp/probe.swift /tmp/composite-test.png
```

Expected: `size=2880x1800 centre=FF0000 corner=0000FF` — overlay red in the middle, base blue at
the edge. If the centre is blue the overlay was not drawn; if the corner is red it was drawn too
large. Adjust `overlayWidthFraction` and re-run Step 3.

- [ ] **Step 5: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
git add fastlane/mac_composite.swift
git commit -m "Add CoreGraphics compositor for Mac screenshots

Draws the Settings window centred over the main-window capture with a
drop shadow and asserts the 2880x1800 App Store size. CoreGraphics
because sips can't composite and ImageMagick would be a new dependency."
```

---

### Task 6: The fastlane lane, gitignore, and docs

**Files:**
- Modify: `fastlane/Fastfile` (append a `platform :mac` block after the existing `platform :ios` block)
- Modify: `.gitignore`
- Modify: `CLAUDE.md` (the Commands section, after the "App Store screenshots" subsection)

**Interfaces:**
- Consumes: the two test methods from Task 4 and the compositor CLI from Task 5.
- Produces: `fastlane screenshots_mac`, writing `fastlane/screenshots_mac/{en-US,de-DE}/0{1..4}_*.png`.

- [ ] **Step 1: Add the lane**

Append to `fastlane/Fastfile`, after the closing `end` of `platform :ios`:

```ruby
platform :mac do
  # Shot key => the Settings-pane overlay it composites from, or nil for a direct capture.
  MAC_SHOTS = {
    "01_Reader" => nil,
    "02_Search" => nil,
    "03_Feeds"  => "03_Feeds.overlay.png",
    "04_AI"     => "04_AI.overlay.png"
  }.freeze

  # Locale => the test method that captures it. Splitting by method (rather than plumbing a
  # TEST_RUNNER_* env var) keeps locale selection to a plain -only-testing argument.
  MAC_LOCALES = {
    "en-US" => "testCaptureScreenshotsEnglish",
    "de-DE" => "testCaptureScreenshotsGerman"
  }.freeze

  desc "Capture Mac App Store screenshots (en-US + de-DE, 2880x1800)"
  lane :screenshots_mac do
    require "json"
    require "fileutils"

    repo_root = File.expand_path("..", __dir__)
    out_root = File.join(repo_root, "fastlane", "screenshots_mac")
    compositor = File.join(repo_root, "fastlane", "mac_composite.swift")

    MAC_LOCALES.each do |locale, test_method|
      UI.header("Capturing #{locale}")

      result_bundle = File.join(Dir.tmpdir, "yana-mac-#{locale}.xcresult")
      attachments = File.join(Dir.tmpdir, "yana-mac-#{locale}-att")
      FileUtils.rm_rf([result_bundle, attachments])

      # Not `scan`/`run_tests`: that action assumes a simulator destination. A direct xcodebuild
      # invocation is the only way to drive the Mac Catalyst destination.
      sh(
        "xcodebuild", "test",
        "-scheme", "Yana",
        "-destination", "platform=macOS,variant=Mac Catalyst",
        "-only-testing:YanaUITests/MacScreenshotUITests/#{test_method}",
        "-resultBundlePath", result_bundle
      )

      sh("xcrun", "xcresulttool", "export", "attachments",
         "--path", result_bundle, "--output-path", attachments)

      manifest_path = File.join(attachments, "manifest.json")
      UI.user_error!("no manifest at #{manifest_path}") unless File.exist?(manifest_path)

      # manifest.json maps each attachment's suggested name to the file actually written on
      # disk (names are uniquified), so resolve through it rather than guessing filenames.
      exported = {}
      JSON.parse(File.read(manifest_path)).each do |test|
        (test["attachments"] || []).each do |attachment|
          name = attachment["suggestedHumanReadableName"]
          file = attachment["exportedFileName"]
          exported[name] = File.join(attachments, file) if name && file
        end
      end

      locale_dir = File.join(out_root, locale)
      FileUtils.mkdir_p(locale_dir)

      base = exported["01_Reader.png"]
      UI.user_error!("01_Reader.png missing from #{locale} run") unless base

      MAC_SHOTS.each do |shot, overlay_name|
        target = File.join(locale_dir, "#{shot}.png")

        if overlay_name.nil?
          source = exported["#{shot}.png"]
          UI.user_error!("#{shot}.png missing from #{locale} run") unless source
          FileUtils.cp(source, target)
        else
          overlay = exported[overlay_name]
          UI.user_error!("#{overlay_name} missing from #{locale} run") unless overlay
          sh("xcrun", "swift", compositor, base, overlay, target)
        end

        UI.success("#{locale}/#{shot}.png")
      end

      FileUtils.rm_rf([result_bundle, attachments])
    end

    UI.success("Mac screenshots written to fastlane/screenshots_mac/")
  end
end
```

- [ ] **Step 2: Ignore result bundles**

In `.gitignore`, the Xcode block currently starts:

```
# Xcode
*.xcodeproj
```

Change to:

```
# Xcode
*.xcodeproj
*.xcresult
```

- [ ] **Step 3: [DEFERRED — USER RUNS] Run the lane end to end**

Requires an unlocked keychain and an interactive GUI session. Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane mac screenshots_mac
```
Expected: `fastlane.tools finished successfully`, with eight `✅ <locale>/<shot>.png` lines.

If it dies with a `FastlanePtyError` or a `"Cr" on UTF-16` crash, the explicit `LANG`/`LC_ALL` above is the fix — the Fastfile's `ENV["LANG"] ||=` does not override an already-set-but-empty `LANG`, since an empty string is truthy in Ruby.

- [ ] **Step 4: [DEFERRED — USER RUNS] Verify every output is exactly 2880×1800**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios
for f in fastlane/screenshots_mac/*/*.png; do
  echo -n "$f: "
  sips -g pixelWidth -g pixelHeight "$f" | tail -2 | tr -d '\n '
  echo
done
```
Expected: eight files, each `pixelWidth:2880pixelHeight:1800`.

- [ ] **Step 5: Confirm the iOS lane is unaffected**

Run:
```bash
cd /Users/skrug/PycharmProjects/yana-ios && git status --short fastlane/screenshots/
```
Expected: **empty output.** The Mac lane must not have touched the iPhone captures or added anything under `fastlane/screenshots/` that `frame_screenshots` would try to frame.

- [ ] **Step 6: Document the lane in CLAUDE.md**

In `CLAUDE.md`, immediately after the existing `### App Store screenshots` subsection (the bullet list ending with the `ScreenshotSeed` idempotency gotcha), insert:

```markdown
### macOS App Store screenshots
- `fastlane mac screenshots_mac` — capture the Mac App Store screenshots (**en-US + de-DE**,
  **2880×1800**, the largest allowed Mac size). Output: `fastlane/screenshots_mac/{en-US,de-DE}/`,
  committed like the iPhone set.
- **This shares nothing with the iPhone lane, by necessity:** `capture_screenshots` (fastlane
  snapshot) drives iOS Simulator destinations only and cannot target Mac Catalyst, and
  `frame_screenshots` (frameit) has no Mac device frames. So the Mac path is its own test
  (`YanaUITests/MacScreenshotUITests.swift`), its own lane, and its own output directory — kept
  **outside** `fastlane/screenshots/` so the iOS lane's `frame_screenshots` never sees it.
- 4-shot set (numeric key = App Store order): `01_Reader` (main window — sidebar + hero article)
  → `02_Search` (sidebar search for "battery") → `03_Feeds` (Settings › Feeds) → `04_AI`
  (Settings › AI). Keep these keys in sync between `MacScreenshotUITests.swift` and `MAC_SHOTS`
  in the Fastfile.
- Shots are **plain captures — no device frame, no gradient, no captions** (the Mac App Store
  convention). Localization comes from the app chrome itself, forced via `-AppleLanguages` /
  `-AppleLocale` launch arguments.
- How it works: the test attaches each window capture as an `XCTAttachment`
  (`lifetime = .keepAlways`) — the only sandbox-safe route out, since the Catalyst test runner
  cannot write outside its container. The lane then runs `xcresulttool export attachments`,
  resolves names through the emitted `manifest.json`, and composites the two Settings shots over
  the `01_Reader` capture with `fastlane/mac_composite.swift` (CoreGraphics; `sips` cannot
  composite and ImageMagick would be a new dependency).
- Content is the same DEBUG-only offline fixture as the iPhone set (`ScreenshotSeed`, via
  `-UITEST_SCREENSHOTS`). Per-locale isolation replaces `erase_simulator`: there is no simulator
  to erase, so the test passes `-UITEST_RESET_LIBRARY` alongside it and relies on `YanaApp`
  running the reset before the seed.
- `-UITEST_MAC_SCREENSHOTS` (`Yana/Utilities/MacScreenshotWindow.swift`) pins the main window to
  1440×900pt — 2880×1800 at 2x — suppresses the Mac launch refresh (whose spinner and error toast
  would otherwise land in a frame), and forces iCloud sync **off**: the app under test shares the
  real `de.fa-krug.Yana` container, so a developer's synced feeds would otherwise appear mid-capture.
- Gotchas: exact sizing assumes a **Retina (2x) display** — the compositor upscales on a 1x host
  rather than emitting an invalid size. Both `YanaTests` and `YanaUITests` must keep
  `SUPPORTS_MACCATALYST`, because `xcodebuild` builds every test target in the scheme even with
  `-only-testing`. The Mac surfaces carry `mac.*` accessibility identifiers purely so the test can
  navigate locale-independently; the sidebar search field is matched as `app.searchFields` because
  `.searchable` does not forward an identifier reliably.
```

- [ ] **Step 7: Commit**

```bash
cd /Users/skrug/PycharmProjects/yana-ios
# fastlane/screenshots_mac/ is NOT committed here: the capture run is deferred to the user
# (locked keychain, see the environment constraint), so the directory does not exist yet.
git add fastlane/Fastfile .gitignore CLAUDE.md
git commit -m "Add screenshots_mac lane and document the Mac capture flow

Runs the Catalyst UI test per locale, exports attachments via
xcresulttool, and composites the Settings shots into 2880x1800 output.
The captures themselves are committed after the first successful run."
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Build configuration | 1 |
| Deterministic window geometry | 2 |
| Accessibility identifiers | 3 |
| Capture flow + shot table | 4 |
| Compositor | 5 |
| Lane, output layout, `.gitignore` | 6 |
| Error handling (assert messages, loud lane failures, size assert, non-Retina) | 2 (fallbacks), 4 (assert messages), 5 (size assert, upscale), 6 (`UI.user_error!`) |
| Testing (screenshot test + geometry unit test) | 2 (unit test), 4 (integration) |
| Documentation | 6 |

One addition beyond the spec: forcing `iCloudSyncEnabled = false` in Task 2. The spec did not anticipate that the Catalyst app under test shares the real `de.fa-krug.Yana` container, so a developer's persisted sync setting could pull live feeds into a capture. This is a determinism requirement, not scope creep.

**Placeholder scan:** none — every code step carries complete code, every command an expected result.

**Type consistency:** `MacScreenshotWindow.launchArgument` / `sizeArgument` / `defaultSize` / `isRequested` / `size(from:)` / `applyWindowGeometryIfRequested()` / `quietBackgroundWorkIfRequested()` are defined in Task 2 and used with those exact names in Tasks 3 and 4. Identifier strings (`mac.sidebar.list`, `mac.settings.window`, `mac.settings.pane.<raw>`) are defined in Task 3 and consumed verbatim in Task 4. Attachment names (`01_Reader.png`, `02_Search.png`, `03_Feeds.overlay.png`, `04_AI.overlay.png`) match between Task 4 and `MAC_SHOTS` in Task 6.
