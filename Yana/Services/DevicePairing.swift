import AuthenticationServices
import Foundation

/// The in-memory state for one pairing attempt. Never persisted — a server-minted state would
/// hand an attacker a valid one too, so the defense is the client holding a secret it generated
/// and never shared (the same pattern `gh auth login --web` uses).
struct DevicePairingSession: Equatable {
    let state: String
}

enum DevicePairingResult: Equatable {
    case success(token: String)
    case stateMismatch
    case malformedCallback
}

enum DevicePairing {
    static func makeSession(randomState: () -> String = { UUID().uuidString }) -> DevicePairingSession {
        DevicePairingSession(state: randomState())
    }

    /// The URL the pairing `WKWebView` loads: the server's login page, carrying a `next` that
    /// chains into `/device/pair` once the user authenticates. The server's `/login` forwards
    /// its `next` query param through unchanged.
    static func pairingURL(serverBaseURL: URL, session: DevicePairingSession, deviceName: String) -> URL {
        var next = URLComponents()
        next.path = "/device/pair"
        next.queryItems = [
            URLQueryItem(name: "state", value: session.state),
            URLQueryItem(name: "scheme", value: "yana"),
            URLQueryItem(name: "deviceName", value: deviceName),
        ]
        let nextString = next.url?.absoluteString ?? ""

        var login = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false)!
        // Append, don't replace: a server reverse-proxied under a path prefix keeps it (audit U6).
        let basePath = login.path.hasSuffix("/") ? String(login.path.dropLast()) : login.path
        login.path = basePath + "/login"
        login.queryItems = [URLQueryItem(name: "next", value: nextString)]
        return login.url!
    }

    /// Called from the pairing `WKWebView`'s navigation delegate when it intercepts a
    /// `yana://auth-callback` navigation, before it becomes a network request.
    static func handleCallback(_ url: URL, session: DevicePairingSession) -> DevicePairingResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              let echoedState = items.first(where: { $0.name == "state" })?.value
        else {
            return .malformedCallback
        }
        guard echoedState == session.state else { return .stateMismatch }
        return .success(token: token)
    }
}

enum PairingFailure: Equatable { case cancelled, sessionFailed, stateMismatch, malformedCallback }
enum PairingOutcome: Equatable { case paired(token: String), failed(PairingFailure) }

extension DevicePairing {
    /// Pure classification of an ASWebAuthenticationSession completion, so the four genuinely
    /// different failure modes (user cancel, session/transport failure, anti-forgery state
    /// mismatch, malformed callback) stop collapsing into one silent "cancelled" (audit U1).
    static func classify(callbackURL: URL?, error: (any Error)?, session: DevicePairingSession) -> PairingOutcome {
        if let error {
            if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                return .failed(.cancelled)
            }
            return .failed(.sessionFailed)
        }
        guard let callbackURL else { return .failed(.cancelled) }
        switch handleCallback(callbackURL, session: session) {
        case .success(let token): return .paired(token: token)
        case .stateMismatch: return .failed(.stateMismatch)
        case .malformedCallback: return .failed(.malformedCallback)
        }
    }
}
