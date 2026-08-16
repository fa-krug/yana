import AuthenticationServices
import Foundation
import Testing
@testable import Yana

@Suite("DevicePairing")
struct DevicePairingTests {
    var session: DevicePairingSession { DevicePairingSession(state: "abc-123") }

    @Test func classifyMapsCancelToCancelled() {
        let err = ASWebAuthenticationSessionError(.canceledLogin)
        #expect(DevicePairing.classify(callbackURL: nil, error: err, session: session) == .failed(.cancelled))
    }

    @Test func classifyMapsOtherErrorsToSessionFailed() {
        struct Boom: Error {}
        #expect(DevicePairing.classify(callbackURL: nil, error: Boom(), session: session) == .failed(.sessionFailed))
    }

    @Test func classifyMapsNilURLNoErrorToCancelled() {
        #expect(DevicePairing.classify(callbackURL: nil, error: nil, session: session) == .failed(.cancelled))
    }

    @Test func classifyForwardsStateMismatch() {
        let url = URL(string: "yana://auth-callback?token=t&state=WRONG")!
        #expect(DevicePairing.classify(callbackURL: url, error: nil, session: session) == .failed(.stateMismatch))
    }

    @Test func classifyForwardsSuccess() {
        let url = URL(string: "yana://auth-callback?token=tok&state=\(session.state)")!
        #expect(DevicePairing.classify(callbackURL: url, error: nil, session: session) == .paired(token: "tok"))
    }

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
