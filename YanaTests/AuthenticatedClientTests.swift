import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("AuthenticatedClient")
struct AuthenticatedClientTests {
    @Test func returnsNilWithoutAServerURLOrToken() {
        let defaults = UserDefaults(suiteName: "AuthenticatedClientTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        KeychainService.deleteDeviceToken()
        #expect(AuthenticatedClient.current(settings: settings) == nil)
    }

    @Test func buildsAClientWhenBothArePresent() {
        let defaults = UserDefaults(suiteName: "AuthenticatedClientTests.\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.serverBaseURL = "https://yana.example.com"
        KeychainService.saveDeviceToken("test-token")
        defer { KeychainService.deleteDeviceToken() }

        let client = AuthenticatedClient.current(settings: settings)
        #expect(client?.baseURL == URL(string: "https://yana.example.com"))
        #expect(client?.token == "test-token")
    }

    /// The default `settings:` argument reads the *developer's* real `UserDefaults` and login
    /// Keychain, so any app code calling `current()` from a unit test could fire a live request
    /// against their own server. It must resolve nothing here no matter how this machine is
    /// paired -- and it must stay exempt for the isolated-suite case above, which the two tests
    /// before this one cover.
    ///
    /// This test deliberately restores whatever real pairing it found instead of deleting it: the
    /// point of the gate is to keep the suite off the developer's server, so breaking their
    /// pairing to prove it would defeat the purpose.
    @Test func refusesToResolveTheDevelopersRealPairingInsideAUnitTest() {
        let settings = AppSettings()
        let realToken = KeychainService.loadDeviceToken()
        let realURL = settings.serverBaseURL
        defer {
            if let realToken { KeychainService.saveDeviceToken(realToken) } else { KeychainService.deleteDeviceToken() }
            settings.serverBaseURL = realURL
        }

        KeychainService.saveDeviceToken("test-token")
        settings.serverBaseURL = "https://yana.example.com"

        #expect(AuthenticatedClient.current() == nil)
    }
}
