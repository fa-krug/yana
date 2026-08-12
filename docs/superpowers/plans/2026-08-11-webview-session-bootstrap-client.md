# Webview Session Bootstrap (Client) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `ManagementWebView` from ever showing a login screen to an already-paired device, on both iOS and Mac Catalyst — including the Mac-only failure where App Sandbox prevents `ASWebAuthenticationSession`'s cookies from ever reaching `WKWebsiteDataStore.default()` in the first place.

**Architecture:** `ManagementWebView` fetches a short-lived, single-use bootstrap token from the server (`POST /api/v1/auth/webview-session-token`, Bearer-authenticated) every time it appears — not just once at pairing time — then loads `GET {serverBaseURL}/webview-session?token=...&next=<path>` into its `WKWebView` instead of loading `path` directly. The server exchanges that token for a real session cookie and redirects into the target page (see the companion server-side plan, `yana-server`'s `docs/superpowers/plans/2026-08-11-webview-session-bootstrap-server.md`, for the endpoint contract this depends on). This makes the existing `CookieMigration` cross-process cookie bridge (which never worked reliably on Mac Catalyst, and only ran once at pairing time even on iOS) obsolete — it is deleted.

**Tech Stack:** SwiftUI, `WKWebView`, `YanaAPIClient`, Swift Testing.

## Global Constraints

- Any new user-facing string must be added to `Yana/Resources/Localizable.xcstrings` with a `de` translation marked `"state": "translated"`. This plan introduces none (the only new UI state is a bare `ProgressView()`, no text).
- `AuthenticatedClient.current()` is a synchronous `@MainActor` function — call it directly, no `await`, from other `@MainActor`-isolated contexts (SwiftUI `View` bodies and their `.task {}` closures already are).
- Server response `Date` fields decode via `YanaAPIClient`'s shared ISO-8601 `JSONDecoder` — no custom `CodingKeys`/date handling needed in new wire types whose property names already match the server's camelCase JSON keys.
- Never let a bootstrap-token fetch failure block the screen indefinitely — always fall back to loading `path` directly (today's existing, if imperfect, behavior) so a network blip or expired pairing never leaves `ManagementWebView` stuck on a spinner.

---

### Task 1: `WebviewSessionToken` wire model

**Files:**
- Create: `Yana/Networking/WebviewSessionToken.swift`
- Test: `YanaTests/WebviewSessionTokenTests.swift`

**Interfaces:**
- Produces: `struct WebviewSessionToken: Decodable, Equatable, Sendable { let token: String; let expiresAt: Date }` — consumed by Task 2's `ManagementWebView` change.

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/WebviewSessionTokenTests.swift
import Foundation
import Testing
@testable import Yana

@Suite("WebviewSessionToken")
struct WebviewSessionTokenTests {
    @Test func decodesTokenAndExpiresAt() throws {
        let json = #"{"token":"abc123","expiresAt":"2026-08-11T12:00:00Z"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(WebviewSessionToken.self, from: json)
        #expect(result.token == "abc123")
        #expect(result.expiresAt == Date(timeIntervalSince1970: 1_786_536_000))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/WebviewSessionTokenTests`
Expected: FAIL — `cannot find 'WebviewSessionToken' in scope`.

- [ ] **Step 3: Implement `WebviewSessionToken`**

```swift
// Yana/Networking/WebviewSessionToken.swift
import Foundation

/// `POST /api/v1/auth/webview-session-token`'s response shape (`yana-server`'s
/// `src/app/api/v1/auth/webview-session-token/route.ts`) -- a short-lived, single-use token
/// `ManagementWebView` exchanges for a real web session by loading it into
/// `GET /webview-session?token=...&next=...`, instead of relying on `ASWebAuthenticationSession`'s
/// cookie jar being visible to `WKWebView` (broken on Mac Catalyst under App Sandbox -- see
/// `ManagementWebView.swift`'s module doc for the constraint this works around).
struct WebviewSessionToken: Decodable, Equatable, Sendable {
    let token: String
    let expiresAt: Date
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/WebviewSessionTokenTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Networking/WebviewSessionToken.swift YanaTests/WebviewSessionTokenTests.swift
git commit -m "feat: add WebviewSessionToken wire model"
```

---

### Task 2: Rewrite `ManagementWebView` to bootstrap a session on every appearance

**Files:**
- Modify: `Yana/Views/ManagementWebView.swift`
- Test: `YanaTests/ManagementWebViewURLTests.swift`

**Interfaces:**
- Consumes: `WebviewSessionToken` (Task 1), `AuthenticatedClient.current()` (existing), `YanaAPIClient.post(_:)` (existing).
- Produces: `static func ManagementWebView.webviewSessionURL(serverBaseURL: URL, token: String, next: String) -> URL` — a pure, unit-testable helper; consumed only by this file's own `resolveLoadURL()`, but tested directly.

- [ ] **Step 1: Write the failing test**

```swift
// YanaTests/ManagementWebViewURLTests.swift
import Foundation
import Testing
@testable import Yana

@Suite("ManagementWebView.webviewSessionURL")
struct ManagementWebViewURLTests {
    @Test func buildsTheBootstrapURLWithTokenAndNext() {
        let url = ManagementWebView.webviewSessionURL(
            serverBaseURL: URL(string: "https://my-yana.example.com")!,
            token: "abc123",
            next: "/feeds/new"
        )
        #expect(url.scheme == "https")
        #expect(url.host == "my-yana.example.com")
        #expect(url.path == "/webview-session")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value) })
        #expect(query["token"] == "abc123")
        #expect(query["next"] == "/feeds/new")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ManagementWebViewURLTests`
Expected: FAIL — `webviewSessionURL` does not exist on `ManagementWebView`.

- [ ] **Step 3: Rewrite `ManagementWebView.swift`**

Replace the entire file:

```swift
// Yana/Views/ManagementWebView.swift
import SwiftUI
import WebKit

/// Hosts the server's own feed/tag/settings web UI. Every time this view appears it bootstraps a
/// fresh browser session for the server via `POST /api/v1/auth/webview-session-token` (a
/// Bearer-authenticated, short-lived, single-use token) and loads the resulting
/// `GET /webview-session?token=...&next=...` URL, which the server exchanges for a real session
/// cookie. This replaced a one-shot cookie copy from `ASWebAuthenticationSession`'s shared cookie
/// jar into `WKWebsiteDataStore.default()`, done once at pairing time -- that approach never
/// reliably reached this WebView's cookie store on Mac Catalyst (App Sandbox isolates the app's
/// `HTTPCookieStorage.shared` from the system's out-of-process Safari auth agent that
/// `ASWebAuthenticationSession` runs through there), and even on iOS it could go stale over time
/// since it was never refreshed after the initial pairing. See
/// `docs/superpowers/plans/2026-08-11-webview-session-bootstrap-client.md`.
struct ManagementWebView: View {
    let serverBaseURL: URL
    var path: String = "/feeds"
    var title: LocalizedStringKey = "Manage"

    @State private var loadURL: URL?

    var body: some View {
        Group {
            if let loadURL {
                ManagementWKWebView(url: loadURL)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolveLoadURL() }
    }

    /// Falls back to loading `path` directly -- today's pre-bootstrap behavior -- on any failure
    /// to mint a bootstrap token (not paired, offline, server error), so a network blip never
    /// leaves this screen stuck on a spinner. That fallback may itself show the server's login
    /// page if there is no valid session at all, exactly as before this change.
    private func resolveLoadURL() async {
        let fallbackURL = serverBaseURL.appendingPathComponent(path)
        guard let client = AuthenticatedClient.current() else {
            loadURL = fallbackURL
            return
        }
        do {
            let bootstrap: WebviewSessionToken = try await client.post("/api/v1/auth/webview-session-token")
            loadURL = Self.webviewSessionURL(serverBaseURL: serverBaseURL, token: bootstrap.token, next: path)
        } catch {
            loadURL = fallbackURL
        }
    }

    static func webviewSessionURL(serverBaseURL: URL, token: String, next: String) -> URL {
        var components = URLComponents(
            url: serverBaseURL.appendingPathComponent("webview-session"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "next", value: next),
        ]
        return components.url!
    }
}

private struct ManagementWKWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ManagementWebViewURLTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/ManagementWebView.swift YanaTests/ManagementWebViewURLTests.swift
git commit -m "feat: bootstrap ManagementWebView's session via one-time token"
```

---

### Task 3: Delete the now-obsolete `CookieMigration` cross-process bridge

**Files:**
- Delete: `Yana/Services/CookieMigration.swift`
- Modify: `Yana/Views/DevicePairingView.swift` (the `finish(callbackURL:)` success case)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — this is pure removal of now-dead code, since Task 2 made `ManagementWebView` independent of the shared-cookie-jar bridge entirely.

- [ ] **Step 1: Confirm nothing else references `CookieMigration`**

Run: `grep -rn "CookieMigration" Yana YanaTests YanaUITests`
Expected: only the two hits this task is about to remove (the file itself and the one call site in `DevicePairingView.swift`). If anything else references it, stop and investigate before deleting.

- [ ] **Step 2: Delete the file**

```bash
git rm Yana/Services/CookieMigration.swift
```

- [ ] **Step 3: Simplify `DevicePairingView.swift`'s success case**

Find this block in `finish(callbackURL:)`:

```swift
        case .success(let token):
            Task {
                await CookieMigration.copySharedCookies(for: serverBaseURL)
                onPaired?(token)
            }
```

Replace it with:

```swift
        case .success(let token):
            onPaired?(token)
```

(`finish` already runs on `@MainActor` — see the `Task { @MainActor in self?.finish(callbackURL: callbackURL) }` call site above it — so no wrapping `Task` is needed once there is nothing left to `await`.)

- [ ] **Step 4: Update `ManagementWebView`'s references to the deleted mechanism, if any remain**

Run: `grep -n "cookie" Yana/Views/ManagementWebView.swift`
Expected: only the `config.websiteDataStore = .default()` line's own comment, which still accurately describes using the persistent data store (now populated by the `/webview-session` redirect's `Set-Cookie`, not by a migrated cookie) — no further edits needed if Task 2 already landed first.

- [ ] **Step 5: Build and run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build test`
Expected: build succeeds (no remaining references to the deleted `CookieMigration` type), all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -u Yana/Views/DevicePairingView.swift
git commit -m "refactor: remove obsolete cross-process cookie bridge"
```

---

### Task 4: Manual verification on both platforms

**Files:** none (verification only).

- [ ] **Step 1: iOS Simulator — fresh pairing**

Run the app in the iOS Simulator (`iPhone 17`), pair with a real (or locally running) `yana-server` instance, then open Settings → Manage Feeds & Tags. Confirm the feed list loads directly with no login screen.

- [ ] **Step 2: iOS Simulator — reopen after a delay**

Force-quit and relaunch the app, then open Manage again. Confirm it still loads directly (this is the case that used to depend on a cookie set once at pairing time — now it re-bootstraps every time, so this should be unaffected by any cookie staleness).

- [ ] **Step 3: Mac Catalyst — fresh pairing (the platform this plan exists to fix)**

Run the Mac Catalyst build, pair with the same server, open Settings → Feeds & Tags verwalten (or the English equivalent). Confirm it loads directly with no login screen — this is the scenario that was broken before this plan (App Sandbox blocking the old cookie bridge).

- [ ] **Step 4: Mac Catalyst — revoke and confirm graceful fallback**

From the server's own web UI (a different browser, signed in as the same user), revoke the paired device's session. Reopen the Mac app's Manage screen. Confirm it falls back to showing the server's real login page (not a crash, not an infinite spinner) — this exercises the `resolveLoadURL()` catch-and-fallback path with a bootstrap-token mint that now legitimately 401s.

- [ ] **Step 5: Report results**

No code changes expected from this task unless a step above surfaces a regression — if one does, treat it as a new bug to fix before considering this plan complete, not as a reason to alter Tasks 1-3's already-committed behavior.

## Self-Review Notes

- **Spec coverage:** wire model (Task 1), `ManagementWebView` bootstrap logic + pure URL builder (Task 2), removal of the superseded mechanism (Task 3), and end-to-end verification on the platform that was actually broken (Task 4) all trace back to the investigation's root cause (Mac Catalyst App Sandbox blocking `ASWebAuthenticationSession` → `HTTPCookieStorage.shared` → `WKWebsiteDataStore` bridging) and the follow-up research (better-auth's `oneTimeToken` plugin as the officially-supported bootstrap mechanism).
- **No placeholders:** every step has real Swift/shell content; Task 4 is verification-only by nature and says so explicitly rather than hiding a coding step inside it.
- **Type/name consistency check:** `WebviewSessionToken.token`/`.expiresAt` (Task 1) match the JSON fields the companion server plan's route returns; `ManagementWebView.webviewSessionURL(serverBaseURL:token:next:)`'s query parameter names (`token`, `next`) match exactly what the server plan's `GET /webview-session` route reads via `url.searchParams.get("token")`/`.get("next")`.
