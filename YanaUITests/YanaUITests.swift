import XCTest

final class YanaUITests: XCTestCase {
    /// Generous timeout for waits gated on a (cold) app launch or a full reader reload. A cold
    /// first launch does migrations + tag bootstrap + ArticleStore load + filter compute before
    /// the empty state renders, which can exceed a few seconds on a loaded/erased simulator, so
    /// tight timeouts here race the launch and flake. See the empty-state gating in TimelineLoadState.
    private static let launchTimeout: TimeInterval = 30
    /// Timeout for in-flow UI transitions (navigation, sheet presentation) once the app is running.
    private static let uiTimeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // Skip the first-launch welcome so it doesn't cover the reader's empty state.
        app.launchArguments += ["-UITEST_SKIP_ONBOARDING"]
        app.launch()
        // The app opens directly into the reader. With no feeds configured yet, the reader
        // shows its empty-state ContentUnavailableView. Assert on a stable accessibility
        // identifier rather than the visible title, which is localized (e.g. "Keine Artikel"
        // on a German-locale simulator).
        XCTAssertTrue(app.staticTexts["emptyArticlesTitle"].waitForExistence(timeout: Self.launchTimeout))
    }

    /// Onboarding: the feeds step shows Add/Import/Finish with no sheet auto-opening; the create
    /// editor opens only via the Add button; and only Finish completes onboarding.
    @MainActor
    func testOnboardingFeedsStepAndFinish() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITEST_RESET_ONBOARDING"]
        app.launch()

        // Welcome → AI → Feeds via the footer Continue button.
        let continueButton = app.buttons["onboardingContinueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: Self.launchTimeout))
        continueButton.tap()                       // welcome → ai
        XCTAssertTrue(continueButton.waitForExistence(timeout: Self.uiTimeout))
        continueButton.tap()                       // ai → feeds

        // The feeds page is shown with its Finish button and no sheet is auto-presented
        // (the create editor has text fields; the feeds page itself has none).
        let finish = app.buttons["onboardingFinishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertFalse(app.textFields.firstMatch.exists,
                       "No create sheet should open automatically on the feeds step")

        // The create editor opens only via the Add button.
        app.buttons["onboardingAddFeedButton"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: Self.uiTimeout),
                      "The Add button should open the create-feed editor")
        app.navigationBars.buttons.element(boundBy: 0).tap()   // Cancel

        // Finish completes onboarding and reveals the reader (empty state here).
        XCTAssertTrue(finish.waitForExistence(timeout: Self.uiTimeout))
        var tries = 0
        while !finish.isHittable, tries < 8 { app.swipeUp(); tries += 1 }
        finish.tap()
        XCTAssertTrue(app.staticTexts["emptyArticlesTitle"].waitForExistence(timeout: Self.launchTimeout))
    }

    /// The Settings "Show Welcome Screen Again" row brings the welcome screen back.
    @MainActor
    func testSettingsRestoreShowsWelcomeAgain() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITEST_SKIP_ONBOARDING"]   // start past onboarding, in the reader
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
        XCTAssertTrue(app.buttons["settings.feeds"].waitForExistence(timeout: Self.uiTimeout))   // Settings opened

        // Scroll to the restore row (About section, bottom of the form) and tap it.
        let restore = app.buttons["settings.showWelcome"]
        var tries = 0
        while !restore.exists, tries < 12 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(restore.waitForExistence(timeout: Self.uiTimeout))
        restore.tap()

        // The welcome screen returns.
        XCTAssertTrue(app.buttons["onboardingContinueButton"].waitForExistence(timeout: Self.uiTimeout),
                      "Restore should re-present the welcome screen")
    }
}
