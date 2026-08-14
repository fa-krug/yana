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
///
/// The same leak applies to the *fake pairing* `ScreenshotSeed.seedIfRequested` installs (a
/// `serverBaseURL` in `UserDefaults` plus a fixture token in the Keychain, so the screenshot run's
/// Settings form shows the "Manage Feeds & Tags" row). Neither lives in the SwiftData store, so
/// wiping the library alone left the next test class launching into a device that still looked
/// paired -- which is what made `testOnboardingStepsAndFinish` fail only in a full run: the server
/// step renders its footer button as `onboardingServerContinueButton` rather than
/// `onboardingSkipServerButton` whenever `AuthenticatedClient.current() != nil`.
enum UITestReset {
    static let launchArgument = "-UITEST_RESET_LIBRARY"

    @MainActor
    static func resetIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        LocalLibraryReset.wipe(context: context)
        // Keychain and UserDefaults both outlive the app container's SwiftData store, so a test
        // asking for a clean slate has to be handed an unpaired one too.
        KeychainService.deleteDeviceToken()
        let settings = AppSettings()
        settings.serverBaseURL = ""
        settings.hasSkippedServerPairing = false
        settings.hasCompletedInitialSync = false
    }
}
#endif
