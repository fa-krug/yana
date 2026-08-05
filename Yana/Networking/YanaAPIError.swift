import Foundation

/// Mirrors the server's `{ "error": { "code": "...", "message": "..." } }` envelope,
/// present on every non-2xx `/api/v1/**` response.
struct YanaAPIError: Error, Equatable, Decodable {
    let code: String
    let message: String
}

private struct YanaAPIErrorEnvelope: Decodable {
    let error: YanaAPIError
}

enum YanaAPIClientError: Error, Equatable {
    case transport
    case decoding
    case unauthorized
    case server(YanaAPIError)
}
