import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("KeychainService")
struct KeychainServiceTests {
    @Test func deviceTokenRoundTrip() {
        KeychainService.deleteDeviceToken()
        defer { KeychainService.deleteDeviceToken() }

        let saved = KeychainService.saveDeviceToken("test-session-token")
        #expect(saved)
        #expect(KeychainService.loadDeviceToken() == "test-session-token")

        KeychainService.deleteDeviceToken()
        #expect(KeychainService.loadDeviceToken() == nil)
    }
}
