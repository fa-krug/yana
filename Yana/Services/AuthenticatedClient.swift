import Foundation

/// Resolves the app's current `YanaAPIClient` from persisted settings + Keychain. `nil` means
/// "not paired yet" -- callers (SyncEngine's app-lifecycle trigger, the image-fetch call sites)
/// treat that as "nothing to do," not an error.
@MainActor
enum AuthenticatedClient {
    static func current(settings: AppSettings = AppSettings()) -> YanaAPIClient? {
        guard !isDisallowedTestResolution(settings),
              !settings.serverBaseURL.isEmpty,
              let baseURL = URL(string: settings.serverBaseURL),
              let token = KeychainService.loadDeviceToken()
        else {
            return nil
        }
        return YanaAPIClient(baseURL: baseURL, token: token)
    }

    /// A unit test runs inside the app's own process, so a default-constructed `AppSettings` reads
    /// the **developer's real** `serverBaseURL` and login Keychain -- which is how a test that
    /// merely parks the timeline on an article could fire a live `PATCH /api/v1/articles/<id>`
    /// against their server (`ArticleWrites.setRead` defaults its `settings:` argument the same
    /// way). The only thing that used to prevent it was fixtures carrying no `serverID`, which is
    /// a rule every future test has to remember; this makes it structural instead.
    ///
    /// Settings built on an isolated `UserDefaults` suite are exempt, so a test that *wants* a
    /// resolved client (`AuthenticatedClientTests`, `ReadingPositionSyncTests`) injects one and
    /// still gets it. A UI test is unaffected: the app it drives is a separate process with no
    /// `XCTestConfigurationFilePath`, and its pairing is the simulator container's own fixture.
    private static func isDisallowedTestResolution(_ settings: AppSettings) -> Bool {
        #if DEBUG
        return TestEnvironment.isRunningUnitTests && settings.usesStandardDefaults
        #else
        return false
        #endif
    }
}
