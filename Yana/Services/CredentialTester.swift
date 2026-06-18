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

/// Builds a client from raw field values (live-network default fetch) and runs its verify
/// method. Pure composition over the per-client `verify*` methods, which carry the logic.
enum CredentialTester {
    static func reddit(clientID: String, clientSecret: String, userAgent: String) async -> CredentialTestError? {
        await RedditClient(clientID: clientID, clientSecret: clientSecret, userAgent: userAgent)
            .verifyCredentials()
    }

    static func youtube(apiKey: String) async -> CredentialTestError? {
        await YouTubeClient(apiKey: apiKey).verifyKey()
    }

    static func ai(provider: AIProvider, apiKey: String, model: String, openaiAPIURL: String) async -> CredentialTestError? {
        let config = AIConfig(
            provider: provider,
            model: model,
            apiKey: apiKey,
            apiBaseURL: openaiAPIURL,
            temperature: 0.0,
            maxTokens: 16,       // tiny probe — keep the test cheap
            requestTimeout: 30,
            maxRetries: 0,
            retryDelay: 0,
            maxRetryTime: 10
        )
        return await AIClient(config: config).verify()
    }
}
