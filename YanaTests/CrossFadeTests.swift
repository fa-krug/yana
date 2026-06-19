import Foundation
import Testing
@testable import Yana

struct CrossFadeTests {
    @Test func durationIsTwoTenthsOfASecond() {
        #expect(CrossFade.duration == 0.2)
    }
}
