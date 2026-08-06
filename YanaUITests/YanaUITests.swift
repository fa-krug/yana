import XCTest

final class YanaUITests: XCTestCase {
    /// Generous timeout for waits gated on a (cold) app launch or a full reader reload. A cold
    /// first launch does migrations + tag bootstrap + ArticleStore load + filter compute before
    /// the empty state renders, which can exceed a few seconds on a loaded/erased simulator, so
    /// tight timeouts here race the launch and flake. See the empty-state gating in TimelineLoadState.
    private static let launchTimeout: TimeInterval = 30
    /// Timeout for in-flow UI transitions (navigation, sheet presentation) once the app is running.
    private static let uiTimeout: TimeInterval = 10

    /// Every test here assumes an empty library. XCTest reuses one simulator app container across
    /// test classes and runs them alphabetically, so `ScreenshotUITests` seeds its fixture library
    /// first and that data persists — which is why these tests pass in isolation but fail in a full
    /// run. Reset the library on launch instead of assuming a fresh container.
    private static let resetLibrary = "-UITEST_RESET_LIBRARY"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Scroll `element` into view inside the Settings form.
    ///
    /// `app.swipeUp()` swipes from the screen centre, which in this form lands on the AI section's
    /// slider/stepper rows and drags a *control value* instead of scrolling — the scroll then stalls
    /// and the About section at the bottom is never reached. Dragging along the leading edge (over
    /// row labels, which are inert) pans the form reliably. Waits for `isHittable`, not `exists`, so
    /// the caller's tap can't land on a row that is only half on screen.
    @MainActor
    private func scrollToSettingsRow(_ element: XCUIElement, in app: XCUIApplication,
                                     maxDrags: Int = 25) -> Bool {
        let form = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        for _ in 0..<maxDrags {
            if element.exists, element.isHittable { return true }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.85))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.20))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return element.exists && element.isHittable
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // Skip the first-launch welcome so it doesn't cover the reader's empty state.
        app.launchArguments += ["-UITEST_SKIP_ONBOARDING", Self.resetLibrary]
        app.launch()
        // The app opens directly into the reader. With no feeds configured yet, the reader
        // shows its empty-state ContentUnavailableView. Assert on a stable accessibility
        // identifier rather than the visible title, which is localized (e.g. "Keine Artikel"
        // on a German-locale simulator).
        XCTAssertTrue(app.staticTexts["emptyArticlesTitle"].waitForExistence(timeout: Self.launchTimeout))
    }

    /// Onboarding: welcome → server pairing → AI mode; the server step shows its address field
    /// with no sheet auto-opening (pairing only starts via its own "Sign In" button, which this
    /// test deliberately doesn't tap -- that opens a WebView against a real Yana Server, out of
    /// scope for this offline UI test), advancing instead via the form's own "Skip for now"
    /// button; and only Finish (on the final AI-mode step) completes onboarding.
    @MainActor
    func testOnboardingStepsAndFinish() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITEST_RESET_ONBOARDING", Self.resetLibrary]
        app.launch()

        // Welcome → Server via the footer Continue button.
        let continueButton = app.buttons["onboardingContinueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: Self.launchTimeout))
        continueButton.tap()                       // welcome → server

        // The server page shows its address field and no sheet is auto-presented.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: Self.uiTimeout),
                      "The server step should show its address text field")
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "No pairing sheet should open automatically on the server step")

        // Server → AI mode via the form's own "Skip for now" button (without pairing -- the
        // re-pairing gate is what catches an unpaired device on the next launch; see ContentView).
        let skipButton = app.buttons["onboardingSkipServerButton"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: Self.uiTimeout))
        skipButton.tap()

        // The AI-mode page is shown with its Finish button.
        let finish = app.buttons["onboardingFinishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: Self.uiTimeout))

        // Finish completes onboarding and reveals the reader. "Skip for now" seeds the demo
        // library (`ScreenshotSeed`), so the reader is showing demo content here, not the empty
        // state -- assert on reader chrome that exists either way.
        finish.tap()
        XCTAssertTrue(app.buttons["reader.menu"].waitForExistence(timeout: Self.launchTimeout))
    }

    /// The Settings "Show Welcome Screen Again" row brings the welcome screen back.
    @MainActor
    func testSettingsRestoreShowsWelcomeAgain() throws {
        let app = XCUIApplication()
        // Reset too: seeded feeds lengthen the Settings form past the swipe budget below.
        app.launchArguments += ["-UITEST_SKIP_ONBOARDING", Self.resetLibrary]
        app.launch()

        // Open Settings via the reader's overflow menu (the empty state keeps the reader chrome;
        // its "Add Your First Feed" button now opens the feed editor, not Settings).
        let menu = app.buttons["reader.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: Self.launchTimeout))
        menu.tap()
        // The Settings menu item is a UIAction, which exposes no accessibility identifier to
        // XCUITest — only its localized title as the label. Match across the app's supported
        // locales so this works on an English or German simulator (keep in sync with translations).
        let settingsButton = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Settings", "Einstellungen"]))
            .firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: Self.uiTimeout))
        settingsButton.tap()
        XCTAssertTrue(app.buttons["settings.manage"].waitForExistence(timeout: Self.uiTimeout))   // Settings opened

        // Scroll to the restore row (About section, bottom of the form) and tap it.
        let restore = app.buttons["settings.showWelcome"]
        XCTAssertTrue(scrollToSettingsRow(restore, in: app),
                      "Could not scroll the Settings form to the restore row")
        restore.tap()

        // The welcome screen returns.
        XCTAssertTrue(app.buttons["onboardingContinueButton"].waitForExistence(timeout: Self.uiTimeout),
                      "Restore should re-present the welcome screen")
    }
}
