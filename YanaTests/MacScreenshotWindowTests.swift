#if DEBUG
import CoreGraphics
import Testing

@testable import Yana

@MainActor
struct MacScreenshotWindowTests {
    @Test func defaultsWhenNoOverridePresent() {
        let size = MacScreenshotWindow.size(from: ["-UITEST_MAC_SCREENSHOTS"])
        #expect(size == MacScreenshotWindow.defaultSize)
    }

    @Test func parsesExplicitOverride() {
        let size = MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "1280x800"])
        #expect(size == CGSize(width: 1280, height: 800))
    }

    @Test func ignoresMalformedOverride() {
        // A garbled value must fall back rather than produce a zero-sized window.
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "wide"])
                == MacScreenshotWindow.defaultSize)
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "1440x"])
                == MacScreenshotWindow.defaultSize)
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE", "0x0"])
                == MacScreenshotWindow.defaultSize)
    }

    @Test func ignoresOverrideWithNoValueFollowing() {
        #expect(MacScreenshotWindow.size(from: ["-UITEST_MAC_WINDOW_SIZE"])
                == MacScreenshotWindow.defaultSize)
    }
}
#endif
