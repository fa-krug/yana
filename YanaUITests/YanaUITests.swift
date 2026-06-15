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
        // shows its empty-state ContentUnavailableView ("All Caught Up").
        XCTAssertTrue(app.staticTexts["All Caught Up"].waitForExistence(timeout: 5))
    }
}
