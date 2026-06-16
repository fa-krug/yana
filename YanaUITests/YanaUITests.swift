import XCTest

final class YanaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        // The app opens directly into the reader. With no feeds configured yet, the reader
        // shows its empty-state ContentUnavailableView. Assert on a stable accessibility
        // identifier rather than the visible title, which is localized (e.g. "Keine Artikel"
        // on a German-locale simulator).
        XCTAssertTrue(app.staticTexts["emptyArticlesTitle"].waitForExistence(timeout: 5))
    }
}
