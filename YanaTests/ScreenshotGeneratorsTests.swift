#if DEBUG
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Screenshot image/logo generators")
struct ScreenshotGeneratorsTests {
    @Test func jpegLeadImageIsWellFormedAndDeterministic() {
        let data = ScreenshotImageFactory.jpeg(index: 0)
        #expect(data.count > 1000)
        #expect(data.count >= 2)
        #expect(data.first == 0xFF)
        #expect(data.dropFirst().first == 0xD8)

        let a = ScreenshotImageFactory.jpeg(index: 3)
        let b = ScreenshotImageFactory.jpeg(index: 3)
        #expect(a == b)
    }

    @Test func pngLogoIsWellFormedAndDeterministic() {
        let data = ScreenshotLogoFactory.png(monogram: "BR", colorHex: "#2E77D0")
        #expect(data.count > 100)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        #expect(Array(data.prefix(4)) == signature)

        let a = ScreenshotLogoFactory.png(monogram: "BR", colorHex: "#2E77D0")
        let b = ScreenshotLogoFactory.png(monogram: "BR", colorHex: "#2E77D0")
        #expect(a == b)
    }
}
#endif
