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
        login.path = "/login"
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
