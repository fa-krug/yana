import Foundation
import Testing
@testable import Yana

struct MotionTests {
    @Test func resolvesToNilWhenReduceMotionIsOn() {
        #expect(Motion.resolve(.snappy, reduceMotion: true) == nil)
    }

    @Test func resolvesToTheAnimationWhenReduceMotionIsOff() {
        #expect(Motion.resolve(.snappy, reduceMotion: false) == .snappy)
    }

    @Test func resolvesNilAnimationToNilWhenReduceMotionIsOff() {
        #expect(Motion.resolve(nil, reduceMotion: false) == nil)
    }
}
