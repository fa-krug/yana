import Testing
import Foundation
@testable import Yana

@MainActor
struct ScreenshotImageFactoryTests {
    @Test func producesNonEmptyJPEG() {
        let data = ScreenshotImageFactory.jpeg(index: 0)
        #expect(data.count > 1000)
        // JPEG SOI marker.
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func isDeterministic() {
        #expect(ScreenshotImageFactory.jpeg(index: 3) == ScreenshotImageFactory.jpeg(index: 3))
    }
}
