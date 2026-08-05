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
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw YanaAPIClientError.decoding
        }
        return decoded
    }

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
