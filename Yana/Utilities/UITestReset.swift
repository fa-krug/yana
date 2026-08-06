#if DEBUG
import Foundation
import SwiftData

/// Wipes the local library so a UI test starts from a known-empty state. Triggered by the
/// `-UITEST_RESET_LIBRARY` launch argument.
///
/// Why this is needed: XCTest runs test classes alphabetically against **one** simulator app
/// container, so `ScreenshotUITests` runs before `YanaUITests` and seeds a full fixture library via
/// `ScreenshotSeed` — and that data survives into the next class, because `ScreenshotSeed` is
/// idempotent and bails as soon as any `Feed` exists. Any test asserting on the reader's empty
/// state (or on a short Settings form) therefore has to reset rather than assume a fresh container,
/// otherwise it passes alone and fails in a full run.
enum UITestReset {
    static let launchArgument = "-UITEST_RESET_LIBRARY"

    @MainActor
    static func resetIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        LocalLibraryReset.wipe(context: context)
    }
}
#endif
