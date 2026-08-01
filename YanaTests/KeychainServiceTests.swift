import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("KeychainService")
struct KeychainServiceTests {

    // MARK: - Helpers

    /// Ensure a clean state before each test by deleting the test key.
    private func cleanup(item: KeychainService.APIKeyItem) {
        KeychainService.deleteAPIKey(for: item)
    }

    // MARK: - Basic round-trip

    @Test func roundTrip() {
        let item = KeychainService.APIKeyItem.mistralAPIKey
        cleanup(item: item)
        defer { cleanup(item: item) }

        let saved = KeychainService.saveAPIKey("test-secret-999", for: item)
        #expect(saved)

        let loaded = KeychainService.loadAPIKey(for: item)
        #expect(loaded == "test-secret-999")

        KeychainService.deleteAPIKey(for: item)
        #expect(KeychainService.loadAPIKey(for: item) == nil)
    }

    // MARK: - CaseIterable conformance

    @Test func apiKeyItemIsCaseIterable() {
        // All 9 cases must be reachable via allCases
        #expect(KeychainService.APIKeyItem.allCases.count == 9)
    }

}