import Testing
@testable import Yana

struct KeychainSyncDefaultTests {
    @Test func defaultsToSynchronizable() {
        #expect(KeychainService.synchronizeWithICloud == true)
    }
}
