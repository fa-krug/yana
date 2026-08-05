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
}
