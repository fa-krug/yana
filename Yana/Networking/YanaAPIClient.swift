import Foundation

/// Thin typed wrapper over every `/api/v1/**` route. Attaches the caller's Bearer token to
/// every request; decodes the server's `{ error: { code, message } }` envelope on failure.
struct YanaAPIClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(path: path, method: "GET", query: query, body: Optional<NoBody>.none)
    }

    func patch<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await send(path: path, method: "PATCH", query: [:], body: body)
    }

    func post<T: Decodable>(_ path: String, body: (some Encodable)? = nil) async throws -> T {
        try await send(path: path, method: "POST", query: [:], body: body)
    }

    /// Body-less overload. `post(_:body:)`'s `body` parameter is an opaque `some Encodable`
    /// sugared generic -- calling it with no argument at all (as every current no-payload POST,
    /// e.g. `/api/v1/articles/:id/reload` and `/api/v1/aggregate`, does) leaves the compiler no
    /// argument to infer that generic's concrete type from, even though it defaults to `nil`:
    /// "generic parameter 'some Encodable' could not be inferred." Confirmed by actually building
    /// `ArticleActions` against this file rather than trusting the brief's sample call sites.
    /// Mirrors `get`'s existing `Optional<NoBody>.none` pattern to sidestep the same inference gap.
    func post<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "POST", query: [:], body: Optional<NoBody>.none)
    }

    /// Raw bytes for a binary response (used for `/images/:hash`), skipping JSON decode.
    func getRaw(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest(path: path, method: "GET", query: [:])
        let (data, response) = try await performRequest(request)
        return (data, response)
    }

    private func send<T: Decodable, Body: Encodable>(
        path: String, method: String, query: [String: String], body: Body?
    ) async throws -> T {
        var request = try makeRequest(path: path, method: method, query: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await performRequest(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw YanaAPIClientError.unauthorized }
            guard let envelope = try? JSONDecoder().decode(YanaAPIErrorEnvelopeDecoder.self, from: data) else {
                throw YanaAPIClientError.transport
            }
            throw YanaAPIClientError.server(envelope.error)
        }
        guard let decoded = try? Self.responseDecoder.decode(T.self, from: data) else {
            throw YanaAPIClientError.decoding
        }
        return decoded
    }

    /// Every server response encodes `Date` fields as ISO 8601 strings (e.g.
    /// `"2026-01-01T00:00:00Z"`, per `yana-server`'s JSON serialization) -- never the
    /// `JSONDecoder` default of a `Double` seconds-since-2001 offset. Without this strategy any
    /// wire type with a `Date` property (`SyncArticleSummaryWire`, `SyncFeedWire`, ...) fails to
    /// decode on every real response, silently surfacing as `YanaAPIClientError.decoding` (the
    /// `try?` above swallows the underlying `DecodingError.typeMismatch`).
    private static let responseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func makeRequest(path: String, method: String, query: [String: String]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw YanaAPIClientError.transport
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw YanaAPIClientError.transport }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw YanaAPIClientError.transport }
            return (data, http)
        } catch let error as YanaAPIClientError {
            throw error
        } catch {
            throw YanaAPIClientError.transport
        }
    }
}

private struct NoBody: Encodable {}

private struct YanaAPIErrorEnvelopeDecoder: Decodable {
    let error: YanaAPIError
}
