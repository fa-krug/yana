import Testing
import CoreGraphics
@testable import Yana

@MainActor
struct SidebarWidthTests {
    @Test func clampBelowMinReturnsMin() {
        #expect(SidebarWidth.clamp(120) == SidebarWidth.min)
    }

    @Test func clampAboveMaxReturnsMax() {
        #expect(SidebarWidth.clamp(999) == SidebarWidth.max)
    }

    @Test func clampWithinRangeIsUnchanged() {
        #expect(SidebarWidth.clamp(400) == 400)
    }
}
