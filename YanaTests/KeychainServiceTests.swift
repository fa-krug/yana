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

    @Test func deviceTokenCacheTracksSaveAndDelete() {
        KeychainService.deleteDeviceToken()
        #expect(KeychainService.loadDeviceToken() == nil)
        KeychainService.saveDeviceToken("token-a")
        #expect(KeychainService.loadDeviceToken() == "token-a")
        #expect(KeychainService.loadDeviceToken() == "token-a")   // second read: cache path
        KeychainService.saveDeviceToken("token-b")
        #expect(KeychainService.loadDeviceToken() == "token-b")
        KeychainService.deleteDeviceToken()
        #expect(KeychainService.loadDeviceToken() == nil)
    }
}
