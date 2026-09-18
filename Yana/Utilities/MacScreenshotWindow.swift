#if DEBUG
import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#endif

/// Forces the Mac window into a fixed size so App Store captures are byte-for-byte reproducible
/// across machines, and silences the asynchronous work that would otherwise bleed into a shot.
///
/// Gated by the `-UITEST_MAC_SCREENSHOTS` launch argument (set only by `MacScreenshotUITests`), so
/// a normal launch is untouched. The default 1440x900pt renders as exactly 2880x1800px on a 2x
/// display — the largest Mac App Store screenshot size.
enum MacScreenshotWindow {
    static let launchArgument = "-UITEST_MAC_SCREENSHOTS"
    static let sizeArgument = "-UITEST_MAC_WINDOW_SIZE"
    static let defaultSize = CGSize(width: 1440, height: 900)

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Parses an optional `-UITEST_MAC_WINDOW_SIZE 1440x900` override, falling back to
    /// `defaultSize` for anything missing, malformed, or non-positive. Pure so it is testable on
    /// every platform (the geometry call below is macOS-only, this is not).
    static func size(from arguments: [String]) -> CGSize {
        guard let flagIndex = arguments.firstIndex(of: sizeArgument),
              case let valueIndex = flagIndex + 1,
              valueIndex < arguments.count
        else { return defaultSize }

        let parts = arguments[valueIndex].split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return defaultSize }

        return CGSize(width: width, height: height)
    }

    /// Pin the main window to the target size. Call from the Mac root view's `onAppear`.
    ///
    /// Deliberately minimal: `setContentSize` on the app's main window is the whole native
    /// implementation. What this replaced was a `UIWindowScene.sizeRestrictions` min == max clamp
    /// plus a 3-second, 100 ms convergence poll — machinery that existed because Mac Catalyst
    /// could only *request* a geometry change from the window server and had to wait to see
    /// whether it took. AppKit sets the size synchronously, so none of that applies.
    ///
    /// **Why there is still a second, deferred pin and not a re-pin observer.** Two things can
    /// change the size after this first call, and neither is the Catalyst negotiation:
    ///
    /// 1. SwiftUI itself may finish its first layout pass after `onAppear` and re-apply a window
    ///    size of its own. One hop to the next main-queue turn is enough to land after it; a
    ///    standing observer would not help, because there is no repeated event to observe.
    /// 2. AppKit constrains a window's frame to the screen's visible area. A 1440x900pt content
    ///    area plus the title bar needs roughly 928pt of usable height, so a display that is only
    ///    900pt tall silently yields a shorter window. **Re-pinning cannot fix that** — the
    ///    constraint would just re-apply — which is why the `screenshots_mac` lane's `sips`
    ///    2880x1800 assertion is the real backstop, and why the capture needs a Retina display
    ///    with enough room rather than merely a Retina display.
    ///
    /// Nothing else resizes the window during a capture run: the lane passes
    /// `-ApplePersistenceIgnoreState YES` so no saved frame is restored, the user is not present
    /// to drag a corner, and the Settings/Welcome windows are separate scenes.
    @MainActor
    static func applyWindowGeometryIfRequested() {
        guard isRequested else { return }

        #if os(macOS)
        let target = size(from: ProcessInfo.processInfo.arguments)
        pin(to: target)
        // See (1) above: land once more after SwiftUI's own first layout pass.
        DispatchQueue.main.async {
            // `assumeIsolated` rather than `Task { @MainActor }`: this must run on the next
            // runloop turn (after SwiftUI's layout pass), and a Task can be scheduled earlier.
            MainActor.assumeIsolated { pin(to: target, reportMismatch: true) }
        }
        #endif
    }

    #if os(macOS)
    /// Set the capture window's content size.
    ///
    /// `NSApp.mainWindow` rather than `windows.first`: `windows` is ordering-undefined and also
    /// contains windows AppKit creates on its own behalf, so `first` is not reliably the document
    /// window even when it is the only one the user can see.
    @MainActor
    private static func pin(to target: CGSize, reportMismatch: Bool = false) {
        guard let window = NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain })
                ?? NSApplication.shared.windows.first
        else { return }
        window.setContentSize(target)
        guard reportMismatch else { return }
        let actual = window.contentLayoutRect.size
        if abs(actual.width - target.width) > 1 || abs(actual.height - target.height) > 1 {
            // Logged rather than asserted: the lane's `sips` check is what fails the run. This
            // just names the cause in the app's own output, where a short display is obvious.
            NSLog("MacScreenshotWindow: wanted \(target), got \(actual) — "
                  + "the display may be too short for a \(target.height)pt content area")
        }
    }
    #endif
}
#endif
