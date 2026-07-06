import XCTest

final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
        snapshot("02_Timeline")

        // Shot 3 — Search.
        searchField.tap()
        searchField.typeText("reader")
        // Let results settle (250ms debounce in ArticleListView).
        Thread.sleep(forTimeInterval: 1.0)
        snapshot("03_Search")

        // Dismiss the article-list sheet.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.swipeDown(velocity: .fast)
        // Let the sheet-dismiss animation finish; the reader's nav bar frame is briefly
        // unreliable to XCUITest mid-transition (hit point resolves to {-1, -1}).
        Thread.sleep(forTimeInterval: 1.0)

        // Shot 4 — Feeds. Open overflow menu -> Settings -> Feeds.
        let menu = app.buttons["reader.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "reader menu missing after dismiss")
        if !menu.isHittable {
            // Reader chrome can auto-hide in full-screen mode; one tap on the body reveals it.
            app.otherElements.firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(menu.isHittable, "reader.menu exists but is not hittable after reveal tap")
        menu.tap()
        app.buttons["Settings"].tap()
        let feeds = app.otherElements["settings.feeds"].exists
            ? app.otherElements["settings.feeds"]
            : app.buttons["settings.feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10), "Feeds link missing")
        feeds.tap()
        // Feeds screen title confirms navigation.
        XCTAssertTrue(app.navigationBars["Feeds"].waitForExistence(timeout: 10), "Feeds screen missing")
        snapshot("04_Feeds")
    }
}
