import Foundation

/// `POST /api/v1/auth/webview-session-token`'s response shape (`yana-server`'s
/// `src/app/api/v1/auth/webview-session-token/route.ts`) -- a short-lived, single-use token
/// `ManagementWebView` exchanges for a real web session by loading it into
/// `GET /webview-session?token=...&next=...`, instead of relying on `ASWebAuthenticationSession`'s
/// cookie jar being visible to `WKWebView` (broken on Mac Catalyst under App Sandbox -- see
/// `ManagementWebView.swift`'s module doc for the constraint this works around).
struct WebviewSessionToken: Decodable, Equatable, Sendable {
    let token: String
    /// Optional so a future server change that stops sending this field degrades to a missing
    /// value instead of failing the whole decode -- nothing in the client currently reads it.
    let expiresAt: Date?
}
