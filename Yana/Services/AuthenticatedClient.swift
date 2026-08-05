import Foundation

/// Resolves the app's current `YanaAPIClient` from persisted settings + Keychain. `nil` means
/// "not paired yet" -- callers (SyncEngine's app-lifecycle trigger, the image-fetch call sites)
/// treat that as "nothing to do," not an error.
@MainActor
enum AuthenticatedClient {
    static func current(settings: AppSettings = AppSettings()) -> YanaAPIClient? {
        guard !settings.serverBaseURL.isEmpty,
              let baseURL = URL(string: settings.serverBaseURL),
              let token = KeychainService.loadDeviceToken()
        else {
            return nil
        }
        return YanaAPIClient(baseURL: baseURL, token: token)
    }
}
