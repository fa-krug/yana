import Foundation
import Testing
@testable import Yana

@Suite("CredentialTestError")
struct CredentialTesterTests {
    @Test func eachCaseHasANonEmptyLocalizedMessage() {
        for error in [CredentialTestError.invalidCredentials, .network, .unexpectedResponse] {
            #expect(!error.localizedMessage.isEmpty)
        }
    }

    @Test func messagesAreDistinct() {
        let messages = Set([
            CredentialTestError.invalidCredentials.localizedMessage,
            CredentialTestError.network.localizedMessage,
            CredentialTestError.unexpectedResponse.localizedMessage,
        ])
        #expect(messages.count == 3)
    }
}
