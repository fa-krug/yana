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
    /// Deliberately minimal: `setContentSize` on the app's first window is the whole native
    /// implementation. What this replaced was a `UIWindowScene.sizeRestrictions` min == max clamp
    /// plus a 3-second, 100 ms convergence poll — machinery that existed because Mac Catalyst
    /// could only *request* a geometry change from the window server and had to wait to see
    /// whether it took. AppKit sets the size synchronously, so none of that applies.
    ///
    /// **Stage 10 owns the rest**: verifying the resulting capture is exactly 2880x1800 against
    /// the real `screenshots_mac` lane, and deciding whether the window also needs pinning on
    /// later activations the way the Catalyst version re-applied on `didActivateNotification`.
    @MainActor
    static func applyWindowGeometryIfRequested() {
        guard isRequested else { return }

        #if os(macOS)
        let target = size(from: ProcessInfo.processInfo.arguments)
        // The main window is the only one up when this runs (the root view's `onAppear`); the
        // Settings and Welcome windows are opened later and explicitly, so there is nothing to
        // disambiguate against here.
        NSApplication.shared.windows.first?.setContentSize(target)
        #endif
    }
}
#endif
