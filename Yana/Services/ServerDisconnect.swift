import Foundation
import SwiftData

/// Un-pairs this device from its Yana Server: deletes the stored Bearer token, clears the server
/// address, wipes every locally mirrored `Article`/`Feed`/`Tag`, and falls back into the same
/// demo-content mode `OnboardingServerPage`'s "Skip for now" already offers -- see
/// docs/superpowers/specs/2026-08-14-remove-server-connection-design.md. Mirrors `PairingSync`'s
/// shape, just running the transition in reverse.
enum ServerDisconnect {
    @MainActor
    static func disconnect(settings: AppSettings, context: ModelContext = AppContainer.shared.mainContext) {
        KeychainService.deleteDeviceToken()
        settings.serverBaseURL = ""
        LocalLibraryReset.wipe(context: context)
        settings.hasSkippedServerPairing = true
        Task {
            await ScreenshotSeed.seed(into: context)
        }
    }
}
