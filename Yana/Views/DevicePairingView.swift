import AuthenticationServices
import SwiftUI

/// Drives the device-pairing flow via `ASWebAuthenticationSession` — a system-managed, Safari-
/// context browser sheet — rather than an in-app `WKWebView`. This is required for iCloud
/// Keychain passkey sign-in to work at all: WKWebView only surfaces platform-authenticator
/// passkeys for a domain the app has declared in its `webcredentials:` Associated Domains
/// entitlement, which is impossible here since the server address is arbitrary and self-hosted
/// (unknown at build time, different per user). `ASWebAuthenticationSession` has no such
/// restriction — it behaves like Safari itself for WebAuthn purposes. Its system-provided sheet
/// also already renders as just a domain label, the web content, and a Cancel button, with no
/// custom chrome for this app to add or remove.
///
/// The trade-off: this session's cookies land in Safari's shared cookie jar
/// (`HTTPCookieStorage.shared`), not the `WKWebsiteDataStore` `ManagementWebView` reads from —
/// the two are entirely separate on iOS, with no automatic sharing. `CookieMigration` copies the
/// resulting session cookies over after a successful pairing so `ManagementWebView` still reuses
/// the session without asking the user to sign in a second time.
struct DevicePairingView: View {
    let serverBaseURL: URL
    let onPaired: (String) -> Void
    let onCancel: () -> Void

    @State private var coordinator = DevicePairingCoordinator()

    var body: some View {
        // The session itself renders as a system-presented sheet on top of this; there is
        // nothing of our own to show underneath it.
        Color.clear
            .onAppear {
                coordinator.start(serverBaseURL: serverBaseURL, onPaired: onPaired, onCancel: onCancel)
            }
    }
}

@MainActor
private final class DevicePairingCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pairingSession: DevicePairingSession?
    private var serverBaseURL: URL?
    private var onPaired: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    func start(serverBaseURL: URL, onPaired: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        let pairingSession = DevicePairing.makeSession()
        self.pairingSession = pairingSession
        self.serverBaseURL = serverBaseURL
        self.onPaired = onPaired
        self.onCancel = onCancel

        let deviceName = UIDevice.current.name
        let url = DevicePairing.pairingURL(serverBaseURL: serverBaseURL, session: pairingSession, deviceName: deviceName)

        let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "yana") { [weak self] callbackURL, _ in
            Task { @MainActor in
                self?.finish(callbackURL: callbackURL)
            }
        }
        authSession.presentationContextProvider = self
        // Non-ephemeral: the resulting session cookie is written to the shared cookie jar
        // (`HTTPCookieStorage.shared`), which `CookieMigration` reads from on success.
        authSession.prefersEphemeralWebBrowserSession = false
        session = authSession
        authSession.start()
    }

    private func finish(callbackURL: URL?) {
        session = nil
        guard let callbackURL, let pairingSession, let serverBaseURL else {
            onCancel?()
            return
        }
        switch DevicePairing.handleCallback(callbackURL, session: pairingSession) {
        case .success(let token):
            Task {
                await CookieMigration.copySharedCookies(for: serverBaseURL)
                onPaired?(token)
            }
        case .stateMismatch, .malformedCallback:
            onCancel?()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // On iOS this delegate callback lands on the main thread, but on Mac Catalyst
        // `ASWebAuthenticationSession` invokes it from a background XPC queue talking to the
        // system's Safari-hosted auth agent — so `MainActor.assumeIsolated` cannot be assumed
        // true here and traps if called directly off-main. Hop to main synchronously instead
        // (this delegate method must return its anchor synchronously, so we can't `await`).
        if Thread.isMainThread {
            return MainActor.assumeIsolated { Self.resolveAnchor() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { Self.resolveAnchor() }
        }
    }

    @MainActor
    private static func resolveAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return keyWindow
        }
        // No key window yet — this method is only ever called while this view is already
        // on screen, so some scene is guaranteed to be connected to anchor a fresh window
        // to (avoiding the scene-less `UIWindow()` initializer, deprecated as of iOS 26).
        return UIWindow(windowScene: scenes.first!)
    }
}
