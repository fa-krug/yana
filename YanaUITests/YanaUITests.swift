import XCTest

final class YanaUITests: XCTestCase {
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
        XCTAssertTrue(app.staticTexts["emptyArticlesTitle"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()                       // welcome → ai
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        continueButton.tap()                       // ai → feeds

        // The feeds page is shown with its Finish button and no sheet is auto-presented
        // (the create editor has text fields; the feeds page itself has none).
        let finish = app.buttons["onboardingFinishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields.firstMatch.exists,
                       "No create sheet should open automatically on the feeds step")

        // The create editor opens only via the Add button.
        app.buttons["onboardingAddFeedButton"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5),
                      "The Add button should open the create-feed editor")
        app.navigationBars.buttons.element(boundBy: 0).tap()   // Cancel

        // Finish completes onboarding and reveals the reader (empty state here).
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        var tries = 0
        while !finish.isHittable, tries < 8 { app.swipeUp(); tries += 1 }
        finish.tap()
        XCTAssertTrue(app.staticTexts["emptyArticlesTitle"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.feeds"].waitForExistence(timeout: 5))   // Settings opened

        // Scroll to the restore row (About section, bottom of the form) and tap it.
        let restore = app.buttons["settings.showWelcome"]
        var tries = 0
        while !restore.exists, tries < 12 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(restore.waitForExistence(timeout: 2))
        restore.tap()

        // The welcome screen returns.
        XCTAssertTrue(app.buttons["onboardingContinueButton"].waitForExistence(timeout: 5),
                      "Restore should re-present the welcome screen")
    }
}
