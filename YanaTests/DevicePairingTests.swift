import Foundation
import Testing
@testable import Yana

@Suite("DevicePairing")
struct DevicePairingTests {
    @Test func pairingURLCarriesStateSchemeAndDeviceName() {
        let session = DevicePairingSession(state: "abc-123")
        let url = DevicePairing.pairingURL(
            serverBaseURL: URL(string: "https://yana.example.com")!,
            session: session,
            deviceName: "Test iPhone"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.path == "/login")
        let next = components.queryItems?.first { $0.name == "next" }?.value ?? ""
        #expect(next.contains("state=abc-123"))
        #expect(next.contains("scheme=yana"))
        #expect(next.contains("deviceName=Test%20iPhone") || next.contains("deviceName=Test+iPhone"))
    }

    @Test func matchingStateExtractsToken() {
        let session = DevicePairingSession(state: "abc-123")
        let callback = URL(string: "yana://auth-callback?token=secret-token&state=abc-123")!
        #expect(DevicePairing.handleCallback(callback, session: session) == .success(token: "secret-token"))
    }

    @Test func mismatchedStateIsRejected() {
        let session = DevicePairingSession(state: "abc-123")
        let callback = URL(string: "yana://auth-callback?token=secret-token&state=wrong")!
        #expect(DevicePairing.handleCallback(callback, session: session) == .stateMismatch)
    }

    @Test func missingTokenOrStateIsMalformed() {
        let session = DevicePairingSession(state: "abc-123")
        let noToken = URL(string: "yana://auth-callback?state=abc-123")!
        #expect(DevicePairing.handleCallback(noToken, session: session) == .malformedCallback)
        let noState = URL(string: "yana://auth-callback?token=secret-token")!
        #expect(DevicePairing.handleCallback(noState, session: session) == .malformedCallback)
    }

    @Test func makeSessionUsesTheInjectedRandomState() {
        let session = DevicePairing.makeSession(randomState: { "fixed-value" })
        #expect(session.state == "fixed-value")
    }
}
