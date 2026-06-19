import Foundation
import Testing
@testable import Yana

@MainActor
struct UpdateProgressTests {
    @Test func idleIsInactive() {
        let p = UpdateProgress()
        #expect(p.isActive == false)
        #expect(p.fraction == 0)
    }

    @Test func startSetsTotalAndActivates() {
        let p = UpdateProgress()
        p.start(total: 4)
        #expect(p.isActive)
        #expect(p.total == 4)
        #expect(p.completed == 0)
        #expect(p.fraction == 0)
    }

    @Test func advanceIncrementsAndClampsToTotal() {
        let p = UpdateProgress()
        p.start(total: 2)
        p.advance()
        #expect(p.completed == 1)
        #expect(p.fraction == 0.5)
        p.advance(); p.advance()
        #expect(p.completed == 2) // clamped
        #expect(p.fraction == 1)
    }

    @Test func resetReturnsToIdle() {
        let p = UpdateProgress()
        p.start(total: 3); p.advance()
        p.reset()
        #expect(p.isActive == false)
        #expect(p.total == 0)
        #expect(p.completed == 0)
    }
}
