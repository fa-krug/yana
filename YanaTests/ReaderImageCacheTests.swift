import Foundation
import Testing
@testable import Yana

@Suite("ReaderImageCache")
struct ReaderImageCacheTests {

    // A modest GIF (few small frames) is kept in full.
    @Test func keepsAllFramesWhenUnderBudget() {
        let limit = ReaderImageCache.animatedFrameLimit(
            perFrameBytes: 480 * 480 * 4, availableFrames: 20,
            budgetBytes: 32 * 1024 * 1024, maxFrames: 240
        )
        #expect(limit == 20)
    }

    // A long GIF is truncated to stay under the byte budget rather than allocating hundreds of MB
    // (the regression that jetsammed the app while preloading a lead-image GIF).
    @Test func truncatesLongGifToBudget() {
        let perFrame = 480 * 480 * 4                 // ~0.9 MB/frame
        let budget = 32 * 1024 * 1024                // 32 MB
        let limit = ReaderImageCache.animatedFrameLimit(
            perFrameBytes: perFrame, availableFrames: 1000, budgetBytes: budget, maxFrames: 240
        )
        #expect(limit < 240)                         // budget binds before the frame cap
        #expect(limit * perFrame <= budget)          // resident set stays within budget
        #expect(limit >= 2)                          // still animates
    }

    // The absolute frame cap bounds a GIF of tiny frames whose byte budget would allow far more.
    @Test func respectsMaxFrameCap() {
        let limit = ReaderImageCache.animatedFrameLimit(
            perFrameBytes: 16 * 16 * 4, availableFrames: 5000,
            budgetBytes: 32 * 1024 * 1024, maxFrames: 240
        )
        #expect(limit == 240)
    }

    // Never drops below two frames even when a single frame already exceeds the budget, so the
    // image still animates instead of degrading to a still.
    @Test func keepsAtLeastTwoFramesWhenOversized() {
        let limit = ReaderImageCache.animatedFrameLimit(
            perFrameBytes: 64 * 1024 * 1024, availableFrames: 10,
            budgetBytes: 32 * 1024 * 1024, maxFrames: 240
        )
        #expect(limit == 2)
    }

    // A single-frame source is not treated as animated.
    @Test func singleFrameIsNotAnimated() {
        let limit = ReaderImageCache.animatedFrameLimit(
            perFrameBytes: 480 * 480 * 4, availableFrames: 1,
            budgetBytes: 32 * 1024 * 1024, maxFrames: 240
        )
        #expect(limit == 1)
    }
}
