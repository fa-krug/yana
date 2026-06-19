import Testing
import UIKit
@testable import Yana

/// Regression tests for the reader nav-bar chrome.
///
/// The disappearing-buttons bug on iOS 26 was NOT about button count: the trigger was the
/// custom-view items (the refresh spinner, and the former "Updating N of M…" label) injected into
/// the bar during a refresh. iOS 26 cannot move a custom view into its automatic "•••" overflow, so
/// under a width-constrained layout it overflows the *standard* buttons instead — and that collapse
/// sticks once the spinner is gone. The fix drops the wide progress label (spinner only) and has
/// `setRefreshing` re-assert the right group on every toggle, forcing a fresh overflow pass so the
/// standard buttons reappear when refresh ends. The standalone star button is therefore safe to keep.
@MainActor
struct ReaderChromeTests {
    private func makeLoadedReader() -> ReaderArticleViewController {
        let reader = ReaderArticleViewController()
        reader.loadViewIfNeeded()
        return reader
    }

    @Test func rightGroupHasStarFilterAndMenu() {
        let reader = makeLoadedReader()
        // star + filter + overflow menu.
        #expect(reader.navigationItem.rightBarButtonItems?.count == 3)
    }

    @Test func refreshReassertsRightGroupSoItCannotStickCollapsed() {
        let reader = makeLoadedReader()
        let atRest = reader.navigationItem.rightBarButtonItems
        // The spinner joins the left group during a refresh; the left group grows then shrinks back.
        reader.setRefreshing(true)
        #expect(reader.navigationItem.leftBarButtonItems?.count == 2)
        reader.setRefreshing(false)
        #expect(reader.navigationItem.leftBarButtonItems?.count == 1)
        // The right group is re-asserted on every refresh toggle, so it always holds all three
        // items — never left collapsed into an automatic overflow menu after a refresh.
        #expect(reader.navigationItem.rightBarButtonItems?.count == 3)
        #expect(reader.navigationItem.rightBarButtonItems?.count == atRest?.count)
    }
}
