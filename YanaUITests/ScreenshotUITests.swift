import XCTest

final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Resolve a button by any of its known localized labels. The screenshot run captures both
    /// en-US and de-DE, so navigation controls whose titles are localized (e.g. "Settings" ⇄
    /// "Einstellungen") must be matched across locales. A single predicate query avoids a
    /// per-label `waitForExistence` stall.
    @MainActor
    private func button(in app: XCUIApplication, labeledAnyOf labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITEST_SCREENSHOTS"]
        setupSnapshot(app)
        app.launch()

        // Shot 1 — Reader. The fixture parks the anchor on a hero article, so the app opens
        // on it. Wait for the article-list toolbar button (only present on the loaded reader).
        let articleList = app.buttons["reader.articleList"]
        XCTAssertTrue(articleList.waitForExistence(timeout: 20), "reader did not load")
        // Feed logos load asynchronously per view (FeedLogoView has no cache), so let them
        // settle before snapping any shot that shows one, otherwise they render as the globe
        // placeholder.
        Thread.sleep(forTimeInterval: 2.0)
        snapshot("01_Reader")

        // Shot 2 — Timeline / article list.
        articleList.tap()
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 5) {
            // On some size classes (e.g. iPad popover) the search bar starts scrolled out of
            // view behind the large title; pull the list down to reveal it.
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "article list did not open")
        Thread.sleep(forTimeInterval: 2.0)   // let per-row feed logos load
        snapshot("02_Timeline")

        // Dismiss the article-list sheet (search not typed yet — navigate to Feeds first).
        let cancel = button(in: app, labeledAnyOf: ["Cancel", "Abbrechen"])
        if cancel.exists { cancel.tap() }
        app.swipeDown(velocity: .fast)
        // Let the sheet-dismiss animation finish; the reader's nav bar frame is briefly
        // unreliable to XCUITest mid-transition (hit point resolves to {-1, -1}).
        Thread.sleep(forTimeInterval: 1.0)

        // Shot 3 — Feeds. Open overflow menu -> Settings -> Feeds.
        let menu = app.buttons["reader.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "reader menu missing after dismiss")
        if !menu.isHittable {
            // Reader chrome can auto-hide in full-screen mode; one tap on the body reveals it.
            app.otherElements.firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(menu.isHittable, "reader.menu exists but is not hittable after reveal tap")
        menu.tap()
        let settingsItem = button(in: app, labeledAnyOf: ["Settings", "Einstellungen"])
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 10), "Settings menu item missing")
        settingsItem.tap()
        let feeds = app.otherElements["settings.feeds"].exists
            ? app.otherElements["settings.feeds"]
            : app.buttons["settings.feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10), "Feeds link missing")
        feeds.tap()
        // Feeds screen title confirms navigation.
        XCTAssertTrue(app.navigationBars["Feeds"].waitForExistence(timeout: 10), "Feeds screen missing")
        Thread.sleep(forTimeInterval: 2.0)   // let per-row feed logos load
        snapshot("03_Feeds")

        // Shot 4 — Search. Navigate back to the article list from Settings.
        // Back out of Feeds → back to Settings root, then dismiss Settings to reach the reader.
        let navBacks = app.navigationBars.buttons.element(boundBy: 0)
        if navBacks.waitForExistence(timeout: 5) { navBacks.tap() }
        // Dismiss the Settings sheet (swipe down or tap Done/close button).
        let doneButton = button(in: app, labeledAnyOf: ["Done", "Fertig"])
        if doneButton.waitForExistence(timeout: 5) {
            doneButton.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Re-open the article list for Search shot.
        let articleList2 = app.buttons["reader.articleList"]
        XCTAssertTrue(articleList2.waitForExistence(timeout: 10), "reader.articleList missing before search")
        articleList2.tap()
        let searchField2 = app.searchFields.firstMatch
        if !searchField2.waitForExistence(timeout: 5) {
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(searchField2.waitForExistence(timeout: 5), "article list did not open for search")

        // Query a term guaranteed to match the real-content fixture
        // ("battery" appears in two authored article titles — Byte Report + Overtake).
        searchField2.tap()
        searchField2.typeText("battery")
        // Let results settle (250ms debounce in ArticleListView).
        Thread.sleep(forTimeInterval: 1.0)
        // Assert the search actually produced rendered rows before snapping — rows are
        // Buttons inside a native List (ArticleListView -> ManagedList), which XCUITest
        // exposes with the "cell" trait.
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5), "search produced no results")
        Thread.sleep(forTimeInterval: 2.0)   // let per-row feed logos load
        snapshot("04_Search")

        // Shot 5 — Settings › AI section. Dismiss the article-list sheet and re-open Settings.
        let cancel2 = button(in: app, labeledAnyOf: ["Cancel", "Abbrechen"])
        if cancel2.exists { cancel2.tap() }
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.0)

        let menu2 = app.buttons["reader.menu"]
        XCTAssertTrue(menu2.waitForExistence(timeout: 10), "reader menu missing before AI shot")
        if !menu2.isHittable {
            app.otherElements.firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(menu2.isHittable, "reader.menu not hittable before AI shot")
        menu2.tap()
        let settingsItem2 = button(in: app, labeledAnyOf: ["Settings", "Einstellungen"])
        XCTAssertTrue(settingsItem2.waitForExistence(timeout: 10), "Settings menu item missing before AI shot")
        settingsItem2.tap()

        // The AI section carries .accessibilityIdentifier("settings.aiSection") in
        // SettingsScreenView, but it sits below the fold in a lazily-rendered SwiftUI Form:
        // off-screen rows are absent from the accessibility tree until scrolled into view, so
        // we must scroll *while* searching for it rather than asserting existence up front.
        let aiSection = app.descendants(matching: .any).matching(identifier: "settings.aiSection").firstMatch
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), "Settings did not open")
        var scrollAttempts = 0
        while !aiSection.exists && scrollAttempts < 12 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.3)
            scrollAttempts += 1
        }
        XCTAssertTrue(aiSection.waitForExistence(timeout: 5), "settings.aiSection not found after scrolling")
        // Nudge it fully on-screen so the key/model/Test fields are visible in the shot.
        scrollAttempts = 0
        while !aiSection.isHittable && scrollAttempts < 5 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.3)
            scrollAttempts += 1
        }
        Thread.sleep(forTimeInterval: 1.0)   // let the view settle
        snapshot("05_AI")
    }
}
