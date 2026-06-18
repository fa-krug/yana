import Foundation

/// The three outcomes a credential test can fail with. Mapped from each client's
/// domain errors so the Settings UI can show a specific, localized message.
enum CredentialTestError: Error, Equatable {
    case invalidCredentials   // provider rejected the key/secret (HTTP 401/403/400, or no token)
    case network              // transport failure, timeout, or server-side (5xx) error
    case unexpectedResponse   // 2xx-but-unparseable, or any other unexpected condition

    var localizedMessage: String {
        switch self {
        case .invalidCredentials:
            String(localized: "Invalid credentials. Check the values and try again.")
        case .network:
            String(localized: "Network error. Check your connection and try again.")
        case .unexpectedResponse:
            String(localized: "Unexpected response from the server.")
        }
    }
}
