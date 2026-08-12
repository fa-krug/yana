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
/// the two are entirely separate on iOS, with no automatic sharing. `ManagementWebView` now
/// bootstraps its own session via a server-issued one-time token, so the shared cookie jar is
/// no longer consulted.
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
    private var onPaired: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    func start(serverBaseURL: URL, onPaired: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        let pairingSession = DevicePairing.makeSession()
        self.pairingSession = pairingSession
        self.onPaired = onPaired
        self.onCancel = onCancel

        let deviceName = UIDevice.current.name
        let url = DevicePairing.pairingURL(serverBaseURL: serverBaseURL, session: pairingSession, deviceName: deviceName)

        // Passing a *reference* to `handleAuthCallback` rather than an inline closure literal
        // matters: a closure literal written textually inside a method of this `@MainActor`
        // class is isolated to it by default (SE-0316), and Swift wraps the closure *value* in
        // an isolation-check thunk that runs before our code — no rewrite of a closure's body
        // could avoid that (confirmed across four different bodies: `Task { @MainActor in }`,
        // plain `DispatchQueue.main.async`, that wrapped in `MainActor.assumeIsolated`, and a
        // body that only called the plain, non-isolated `perform(_:on:with:waitUntilDone:)` —
        // all four crashed at the identical symbol, before ever reaching the body). That thunk
        // traps (`EXC_BREAKPOINT` in `dispatch_assert_queue`) on the background XPC queue
        // (`com.apple.NSXPCConnection...SafariLaunchAgent`) this completion handler actually
        // fires from on Mac Catalyst. `handleAuthCallback` below is declared `nonisolated`, so a
        // reference to it carries no such isolation for Swift to wrap — exactly why
        // `presentationAnchor`'s `nonisolated` method (not a closure) never had this problem.
        let authSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "yana",
            completionHandler: handleAuthCallback
        )
        authSession.presentationContextProvider = self
        // Non-ephemeral: the resulting session cookie is written to the shared cookie jar
        // (`HTTPCookieStorage.shared`), persisting the pairing session.
        authSession.prefersEphemeralWebBrowserSession = false
        session = authSession
        authSession.start()
    }

    // `nonisolated` so this can be referenced directly as `ASWebAuthenticationSession`'s
    // completion handler with no closure-isolation wrapping — see the comment at the call site
    // in `start`. `perform(_:on:with:waitUntilDone:)` dispatches by Objective-C selector onto the
    // main thread's run loop, which (unlike a Swift `Task`/`DispatchQueue` hop from here) needs
    // no Swift Concurrency executor check on the way, so it can't hit the same trap.
    nonisolated private func handleAuthCallback(_ callbackURL: URL?, _ error: (any Error)?) {
        perform(#selector(finishFromCallback(_:)), on: Thread.main, with: callbackURL, waitUntilDone: false)
    }

    // `@objc` target for the `perform(_:on:with:waitUntilDone:)` hop above — `perform` passes
    // its `with:` argument as a plain `Any?`, so this just re-narrows it back to `URL?` before
    // forwarding to the real (isolated) handler.
    @objc private func finishFromCallback(_ callbackURL: Any?) {
        finish(callbackURL: callbackURL as? URL)
    }

    private func finish(callbackURL: URL?) {
        session = nil
        // `pairingSession` alone is the "has start() been called" gate -- it's set together with
        // (and never outlives) the local `serverBaseURL` `start()` used to build the pairing URL,
        // so there's no separate value from that URL still needed here.
        guard let callbackURL, let pairingSession else {
            onCancel?()
            return
        }
        switch DevicePairing.handleCallback(callbackURL, session: pairingSession) {
        case .success(let token):
            onPaired?(token)
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
