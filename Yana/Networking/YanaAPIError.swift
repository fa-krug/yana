import Foundation

/// Mirrors the server's `{ "error": { "code": "...", "message": "..." } }` envelope,
/// present on every non-2xx `/api/v1/**` response.
struct YanaAPIError: Error, Equatable, Decodable {
    let code: String
    let message: String
}

enum YanaAPIClientError: Error, Equatable {
    case transport
    /// Carries the underlying `DecodingError`'s description (e.g. which key/type mismatched) so a
    /// server-side wire-shape change surfaces as an actionable message instead of a bare case.
    case decoding(String)
    case unauthorized
    /// A non-2xx response whose body is not the server's `{ error: { code, message } }` envelope --
    /// an HTML 404 from a server predating a route, a reverse proxy's 502, a Next.js 500 page.
    /// Distinct from `.transport` (which means the request never got an HTTP response at all),
    /// because "this route does not exist on your server" and "you are offline" call for very
    /// different user-facing advice and were previously indistinguishable.
    case unexpectedStatus(Int)
    case server(YanaAPIError)
}
