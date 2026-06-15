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
        // shows its empty-state ContentUnavailableView ("No Articles").
        XCTAssertTrue(app.staticTexts["No Articles"].waitForExistence(timeout: 5))
    }
}
