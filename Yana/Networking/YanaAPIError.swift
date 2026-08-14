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
    case server(YanaAPIError)
}
