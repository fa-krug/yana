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
            // Suppress iCloud sync so it cannot interfere with seeded state.
            // Uses the argument domain — nothing persists to the real UserDefaults store.
            "-settings.iCloudSyncEnabled", "0",
            // Force the active AI provider to OpenAI so the AI pane shows a deterministic
            // set of fields (API key + URL + model) regardless of any prior user config.
            // Key: AppSettings.Key.activeAIProvider ("settings.activeAIProvider", line 118 in
            // AppSettings.swift); stored value: AIProvider.openai.rawValue == "openai" (line 5).
            // Uses the argument domain — nothing persists to the real UserDefaults store.
            "-settings.activeAIProvider", "openai",
            // Mac Catalyst is AppKit-hosted and PERSISTS window state, so a Settings window left
            // open by a previous run gets restored on the next launch — which silently changed
            // which window `app.windows` returned first and produced a 1440x1344 capture of the
            // restored Settings window instead of the main window. This is the standard AppKit
            // flag to ignore saved window state, so every run starts with just the main window.
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()

        // Shot 1 — main window: sidebar + the hero article the seed parked the anchor on.
        let sidebar = app.descendants(matching: .any).matching(identifier: "mac.sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 60),
                      "Mac sidebar never appeared — seeding may have failed")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 60),
                      "sidebar rendered no article rows")
        Thread.sleep(forTimeInterval: Self.logoSettle)
        let mainWindow = Self.window(of: app, containing: "mac.sidebar.list")
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "main window not found by content")
        attach(mainWindow.screenshot(), named: "01_Reader.png",
               expectedPixelSize: CGSize(width: 2880, height: 1800))

        // Shot 2 — search. The field is matched by element type, not identifier: `.searchable`
        // does not forward an accessibilityIdentifier reliably, and searchFields is already
        // locale-independent.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "sidebar search field missing")
        search.click()
        search.typeText("battery")
        // 250ms debounce in MacSidebarView, plus the predicate fetch.
        Thread.sleep(forTimeInterval: 1.5)
        // Assert a result row actually matching the query appeared — not merely that rows exist,
        // since the unfiltered list has rows too.
        //
        // Match `staticTexts`, NOT `cells`: on the Catalyst source list the Cell element carries no
        // label of its own (verified against a captured accessibility hierarchy — the cells came
        // back as bare `Cell, 0x…, {{610,288},{340,71}}`). `MacArticleRow`'s
        // `.accessibilityElement(children: .combine)` label lands on a child StaticText instead,
        // e.g. 'Feed logo, The truth about fast charging and battery health, Overtake, ·, July 25, 2026'.
        let batteryRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[cd] 'battery'")
        ).firstMatch
        XCTAssertTrue(batteryRow.waitForExistence(timeout: 15),
                      "search for \"battery\" produced no matching rows (checked staticTexts labels)")
        Thread.sleep(forTimeInterval: Self.logoSettle)
        attach(mainWindow.screenshot(), named: "02_Search.png",
               expectedPixelSize: CGSize(width: 2880, height: 1800))

        // Shots 3 and 4 — the Settings window, captured at its natural size. The lane composites
        // these over 01_Reader. Capturing the main window while Settings floats over it risks the
        // occluding window bleeding in, which is why 01_Reader is reused as the base.
        let settingsWindow = try openSettings(in: app)

        try selectPane("feeds", in: app)
        Thread.sleep(forTimeInterval: Self.logoSettle)
        assertPlausibleSettingsWindow(settingsWindow, pane: "feeds")
        attach(settingsWindow.screenshot(), named: "03_Feeds.overlay.png",
               expectedPixelSize: nil)

        try selectPane("ai", in: app)
        Thread.sleep(forTimeInterval: 1.0)
        assertPlausibleSettingsWindow(settingsWindow, pane: "ai")
        attach(settingsWindow.screenshot(), named: "04_AI.overlay.png",
               expectedPixelSize: nil)
    }

    /// Guard against capturing something that is not the whole Settings window. `MacSettingsWindow`
    /// declares `minWidth: 700, minHeight: 560`, so anything smaller means the query resolved to an
    /// inner view (SwiftUI propagates identifiers to descendants) or to the wrong window entirely.
    @MainActor
    private func assertPlausibleSettingsWindow(_ window: XCUIElement, pane: String) {
        let frame = window.frame
        XCTAssertTrue(frame.width >= 700 && frame.height >= 560,
                      "Settings capture target for the \(pane) pane is too small: \(frame)")
    }

    /// Resolve a WINDOW by a marker identifier somewhere inside it.
    ///
    /// Two problems this avoids. `app.windows.firstMatch` is order-undefined, and once a Settings
    /// window exists (including one RESTORED from a previous run) it can return that instead of the
    /// main window — observed as a 1440x1344 capture of the Settings window where 2880x1800 was
    /// expected. And `descendants(matching: .any).matching(identifier:)` can bind to an inner view,
    /// because SwiftUI propagates an accessibility identifier to descendants. Constraining the query
    /// to `.windows` and selecting by contained marker fixes both: the result is always a window,
    /// and always the right one.
    @MainActor
    private static func window(of app: XCUIApplication, containing identifier: String) -> XCUIElement {
        app.windows.containing(.any, identifier: identifier).firstMatch
    }

    // MARK: - Navigation

    /// Open Settings with ⌘, falling back to the toolbar overflow menu.
    @MainActor
    private func openSettings(in app: XCUIApplication) throws -> XCUIElement {
        // Resolve the Settings WINDOW by a marker inside it (a pane row), not by the
        // `mac.settings.window` identifier on the root view — that identifier propagates to
        // descendants, so `firstMatch` could bind to an inner view and we would screenshot a
        // fragment. `general` is always present: it is the first `SettingsPane` case.
        let window = Self.window(of: app, containing: "mac.settings.pane.general")

        app.typeKey(",", modifierFlags: .command)
        if window.waitForExistence(timeout: 10) { return window }

        // Fallback: the ellipsis button in MacRootView's .primaryAction toolbar group. It has no
        // identifier, so match the SF Symbol image name or its localized label across locales.
        // Wait for the named button FIRST before evaluating .exists — sampling .exists before the
        // toolbar is in the accessibility tree would always return false and bind the wrong
        // (positional) fallback, making the subsequent waitForExistence wait on a ghost element.
        let namedOverflow = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["ellipsis.circle", "More", "Mehr"])
        ).firstMatch
        let overflow: XCUIElement
        if namedOverflow.waitForExistence(timeout: 5) {
            overflow = namedOverflow
        } else {
            let count = app.toolbars.buttons.count
            guard count > 0 else {
                XCTFail("Toolbar overflow fallback: no toolbar buttons found — cannot open Settings")
                throw XCTSkip("No toolbar buttons available for Settings fallback")
            }
            overflow = app.toolbars.buttons.element(boundBy: count - 1)
        }
        XCTAssertTrue(overflow.waitForExistence(timeout: 10),
                      "neither ⌘, nor the toolbar overflow could open Settings")
        overflow.click()
        // Match on `identifier` (and `title` as a belt-and-braces alternative), NOT `label`: a
        // macOS NSMenuItem carries its text in `title` and leaves `label` empty, so a label-based
        // predicate never matches. Verified against a captured accessibility hierarchy, where the
        // item came back as:
        //   MenuItem, 0x…, identifier: 'settings', title: 'Settings'
        // The identifier is derived from the command, so it stays 'settings' in every locale —
        // which is why it is preferred over the localized title.
        let item = app.menuItems.matching(
            NSPredicate(format: "identifier == 'settings' OR title IN %@",
                        ["Settings", "Einstellungen"])
        ).firstMatch
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

        // Prefer a plain click, but fall back to a coordinate click. SwiftUI propagates an
        // accessibility identifier to descendants, so `firstMatch` can resolve to a small
        // non-hittable child (observed: the row's 15x12 SF Symbol image) even though the row
        // itself is perfectly clickable. A coordinate click is not subject to the hittability
        // check, and the child's centre still lies inside the row — so it selects the pane either
        // way. `.accessibilityElement(children: .combine)` in MacSettingsWindow should make the
        // element the whole row, but this keeps the test working if that ever regresses.
        if row.isHittable {
            row.click()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - Attachments

    /// Attach a screenshot as a test artifact.
    ///
    /// - Parameters:
    ///   - screenshot: The screenshot to attach.
    ///   - name: The attachment file name (used by the lane's export step).
    ///   - expectedPixelSize: When non-nil, the screenshot's pixel dimensions must match exactly.
    ///     Pass the expected size for full-window captures; pass `nil` for overlay captures whose
    ///     size varies with the floating window bounds.
    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, named name: String,
                        expectedPixelSize: CGSize?) {
        if let expected = expectedPixelSize {
            guard let actual = Self.pngPixelSize(screenshot.pngRepresentation) else {
                return XCTFail("\(name): could not read PNG dimensions from the screenshot")
            }
            XCTAssertEqual(actual.width, Int(expected.width),
                           "\(name): pixel width \(actual.width) ≠ expected \(Int(expected.width)) "
                           + "(full size \(actual.width)x\(actual.height))")
            XCTAssertEqual(actual.height, Int(expected.height),
                           "\(name): pixel height \(actual.height) ≠ expected \(Int(expected.height)) "
                           + "(full size \(actual.width)x\(actual.height))")
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        // Without .keepAlways the attachment is discarded on success — which is every run we
        // actually want the images from.
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Read a PNG's pixel dimensions straight from its IHDR header.
    ///
    /// Deliberately NOT via `XCUIScreenshot.image`: the iOS SDK types that as `UIImage`, but the
    /// Mac Catalyst UI-test runner is a real AppKit process and hands back an `NSImage` at runtime,
    /// so `.scale` raises "unrecognized selector". Parsing the bytes sidesteps the whole
    /// UIImage/NSImage ambiguity and gives true pixels rather than points × scale.
    ///
    /// Layout: 8-byte signature, then the IHDR chunk (4-byte length, 4-byte type `IHDR`), whose
    /// first two fields are width and height as big-endian `UInt32`.
    private static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        func be32(_ offset: Int) -> Int {
            Int(data.dropFirst(offset).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        let width = be32(16)
        let height = be32(20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
#endif
