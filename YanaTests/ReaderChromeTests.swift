import Testing
import UIKit
@testable import Yana

/// Regression tests for the reader nav-bar chrome.
///
/// A fourth right-side button overflows the bar on width-constrained displays (e.g. Display
/// Zoom), and iOS 26 then collapses every button into an automatic "•••" overflow menu that
/// sticks even after the refresh spinner is removed. Starring therefore lives in the overflow
/// menu, leaving the right group at two items (filter + menu) so the bar keeps headroom for the
/// refresh spinner that briefly joins the left group.
@MainActor
struct ReaderChromeTests {
    private func makeLoadedReader() -> ReaderArticleViewController {
        let reader = ReaderArticleViewController()
        reader.loadViewIfNeeded()
        return reader
    }

    @Test func rightGroupHasTwoItems() {
        let reader = makeLoadedReader()
        // filter + overflow menu only — no standalone star button.
        #expect(reader.navigationItem.rightBarButtonItems?.count == 2)
    }

    @Test func refreshSpinnerKeepsTotalItemsWithinBudget() {
        let reader = makeLoadedReader()
        func total() -> Int {
            (reader.navigationItem.leftBarButtonItems?.count ?? 0)
                + (reader.navigationItem.rightBarButtonItems?.count ?? 0)
        }
        // At rest: 1 left + 2 right = 3.
        #expect(total() == 3)
        // While refreshing the spinner joins the left group: at most 4 bar items.
        reader.setRefreshing(true)
        #expect(total() <= 4)
        reader.setRefreshing(false)
        #expect(total() == 3)
    }
}
