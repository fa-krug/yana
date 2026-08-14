import CoreGraphics
import Testing
@testable import Yana

/// `ManagedList` keeps its rows invisible until the row it scrolled to is genuinely on screen, so
/// opening the article list never shows the list travelling from the top down to the current
/// article. These pin the geometric half of that rule.
@Suite("Managed list reveal")
struct ManagedListRevealTests {
    private let list = CGRect(x: 0, y: 100, width: 390, height: 600)

    @Test("A row fully inside the list is visible")
    func rowInside() {
        let row = CGRect(x: 0, y: 300, width: 390, height: 80)
        #expect(ManagedListReveal.isRowFullyVisible(row: row, inList: list))
    }

    @Test("A row clipped by the top edge is not visible yet")
    func rowClippedAtTop() {
        let row = CGRect(x: 0, y: 60, width: 390, height: 80)
        #expect(!ManagedListReveal.isRowFullyVisible(row: row, inList: list))
    }

    @Test("A row clipped by the bottom edge is not visible yet")
    func rowClippedAtBottom() {
        let row = CGRect(x: 0, y: 660, width: 390, height: 80)
        #expect(!ManagedListReveal.isRowFullyVisible(row: row, inList: list))
    }

    @Test("A row flush with both edges counts as visible")
    func rowFlushWithEdges() {
        #expect(ManagedListReveal.isRowFullyVisible(row: list, inList: list))
    }

    /// The list's frame starts out unmeasured; revealing then would defeat the whole point.
    @Test("An unmeasured list is never visible")
    func unmeasuredList() {
        let row = CGRect(x: 0, y: 300, width: 390, height: 80)
        #expect(!ManagedListReveal.isRowFullyVisible(row: row, inList: .zero))
    }

    /// A row can report a zero-height frame mid-layout; that is not a landed position either.
    @Test("A zero-height row is never visible")
    func zeroHeightRow() {
        let row = CGRect(x: 0, y: 300, width: 390, height: 0)
        #expect(!ManagedListReveal.isRowFullyVisible(row: row, inList: list))
    }
}
