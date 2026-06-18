import Foundation

/// Immutable, `Sendable` snapshot of the AI configuration for one run. Built on the main
/// actor from `AppSettings` + `KeychainService`, then handed to off-main code. `provider`
/// is resolved to a concrete one (`.openai`/`.anthropic`/`.gemini`); `.none` means AI is off
/// and no `AIClient` is constructed.
struct AIConfig: Sendable, Equatable {
    var provider: AIProvider
    var model: String
    var apiKey: String
    var openaiAPIURL: String
    var temperature: Double
    var maxTokens: Int
    var requestTimeout: Int
    var maxRetries: Int
    var retryDelay: Int
    /// Total seconds the retry loop may consume before giving up (server `ai_max_retry_time`).
    var maxRetryTime: Int
}

enum AIClientError: Error, Equatable {
    case unsupportedProvider          // .none reached the client (programmer error)
    case httpStatus(Int)              // non-2xx, non-retryable, or retries exhausted
    case invalidResponseShape         // provider JSON did not contain the expected text path
}

/// Talks to one of three LLM providers in JSON mode. The only side effect is the injected
/// `fetch` closure (defaults to `URLSession`), so tests supply canned responses with no
/// live network. Retries on HTTP 429 only, with exponential backoff capped by a time budget.
struct AIClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let config: AIConfig
    let fetch: Fetch

    init(config: AIConfig, fetch: @escaping Fetch = AIClient.defaultFetch) {
        self.config = config
        self.fetch = fetch
    }

    static let defaultFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponseShape
        }
        return (data, http)
    }

    /// Generate a response from the active provider. `jsonMode` requests structured JSON
    /// where the provider supports it. Returns the raw text payload (still a JSON string for
    /// our prompts); throws on transport / status / shape failure.
    func generate(prompt: String, jsonMode: Bool) async throws -> String {
        let (request, parse) = try buildRequest(prompt: prompt, jsonMode: jsonMode)
        let data = try await send(request)
        return try parse(data)
    }

    /// Minimal credential check: a tiny non-JSON generation. Returns nil when the provider
    /// accepts the key and returns a parseable response. Callers should build the `AIConfig`
    /// with a small `maxTokens` so the probe is cheap.
    func verify() async -> CredentialTestError? {
        do {
            _ = try await generate(prompt: "ping", jsonMode: false)
            return nil
        } catch AIClientError.httpStatus(let code) {
            return (code == 401 || code == 403 || code == 400) ? .invalidCredentials : .unexpectedResponse
        } catch AIClientError.invalidResponseShape, AIClientError.unsupportedProvider {
            return .unexpectedResponse
        } catch is URLError {
            return .network
        } catch {
            // unparseable body / other unexpected errors
            return .unexpectedResponse
        }
    }

    // MARK: - Request building (per provider)

    private func buildRequest(
        prompt: String,
        jsonMode: Bool
    ) throws -> (URLRequest, @Sendable (Data) throws -> String) {
        switch config.provider {
        case .openai: return (try openaiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseOpenAI)
        case .anthropic: return (try anthropicRequest(prompt: prompt), Self.parseAnthropic)
        case .gemini: return (try geminiRequest(prompt: prompt, jsonMode: jsonMode), Self.parseGemini)
        case .none, .appleIntelligence: throw AIClientError.unsupportedProvider
        }
    }

    private func jsonRequest(url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(config.requestTimeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func openaiRequest(prompt: String, jsonMode: Bool) throws -> URLRequest {
        guard let url = URL(string: "\(config.openaiAPIURL)/chat/completions") else {
            throw AIClientError.invalidResponseShape
        }
        var body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        return try jsonRequest(url: url, headers: ["Authorization": "Bearer \(config.apiKey)"], body: body)
    }

    private func anthropicRequest(prompt: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIClientError.invalidResponseShape
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
        ]
        return try jsonRequest(
            url: url,
            headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
            body: body
        )
    }

    private func geminiRequest(prompt: String, jsonMode: Bool) throws -> URLRequest {
        let model = config.model
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        else { throw AIClientError.invalidResponseShape }

        var generationConfig: [String: Any] = [
            "temperature": config.temperature,
            "maxOutputTokens": config.maxTokens,
        ]
        if jsonMode {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = [
                "type": "OBJECT",
                "properties": [
                    "title": ["type": "STRING"],
                    "content": ["type": "STRING"],
                ],
                "required": ["title", "content"],
            ]
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig,
        ]
        return try jsonRequest(url: url, headers: ["x-goog-api-key": config.apiKey], body: body)
    }

    // MARK: - Response parsing (per provider)

    private static let parseOpenAI: @Sendable (Data) throws -> String = { data in
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw AIClientError.invalidResponseShape }
        return content
    }

    private static let parseAnthropic: @Sendable (Data) throws -> String = { data in
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = obj["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String
        else { throw AIClientError.invalidResponseShape }
        return text
    }

    private static let parseGemini: @Sendable (Data) throws -> String = { data in
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { throw AIClientError.invalidResponseShape }
        return text
    }

    // MARK: - Send with 429-only retry + backoff + time budget

    private func send(_ request: URLRequest) async throws -> Data {
        let start = Date()
        var attempt = 0
        while true {
            let (data, http) = try await fetch(request)
            if (200..<300).contains(http.statusCode) {
                return data
            }
            // Retry on 429 only, while attempts remain.
            guard http.statusCode == 429, attempt < config.maxRetries else {
                throw AIClientError.httpStatus(http.statusCode)
            }
            // Exponential backoff: retryDelay * 2^attempt, capped by the total time budget.
            let wait = config.retryDelay > 0 ? Double(config.retryDelay) * pow(2, Double(attempt)) : 0
            let elapsed = Date().timeIntervalSince(start)
            if wait > 0, elapsed + wait > Double(config.maxRetryTime) {
                throw AIClientError.httpStatus(http.statusCode)
            }
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            attempt += 1
        }
    }
}
