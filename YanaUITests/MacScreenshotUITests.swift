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
        // Use select-all + delete rather than the NSSearchField clear button: the clear
        // button only exists once text is typed AND the field has focus, so an element-
        // based tap can raise a hard failure and abort the run — losing shots 3 and 4.
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
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
        // Wait for the identifier-based button FIRST before evaluating .exists — sampling .exists
        // before the toolbar is in the accessibility tree would always return false and bind the
        // wrong (positional) fallback, making the subsequent waitForExistence wait on a ghost element.
        let namedOverflow = app.buttons["ellipsis.circle"]
        let overflow: XCUIElement
        if namedOverflow.waitForExistence(timeout: 5) {
            overflow = namedOverflow
        } else {
            overflow = app.toolbars.buttons.element(boundBy: app.toolbars.buttons.count - 1)
        }
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
