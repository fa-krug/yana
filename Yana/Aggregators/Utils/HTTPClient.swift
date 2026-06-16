import Foundation

/// Async HTTP wrapper: browser-ish UA, timeout, retry with exponential backoff,
/// and `AggregatorError.articleSkip` on 4xx (mirrors the server's html_fetcher + ArticleSkipError).
enum HTTPClient {
    static let userAgent = "Mozilla/5.0 (compatible; YanaBot/1.0; +https://github.com/fa-krug/Yana)"

    static func fetchHTML(_ url: URL, timeout: TimeInterval = 30) async throws -> String {
        let (data, _) = try await fetchData(url, timeout: timeout)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw AggregatorError.parse("response was not decodable text")
        }
        return html
    }

    static func fetchData(_ url: URL, timeout: TimeInterval = 30) async throws -> (data: Data, contentType: String?) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    static func fetchJSON(_ request: URLRequest) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return try await send(request).data
    }

    private static func send(_ request: URLRequest, maxAttempts: Int = 3) async throws -> (data: Data, contentType: String?) {
        var lastError: Error = AggregatorError.contentFetch("unknown")
        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if (400..<500).contains(http.statusCode) {
                        throw AggregatorError.articleSkip(statusCode: http.statusCode)
                    }
                    if http.statusCode >= 500 {
                        throw AggregatorError.contentFetch("HTTP \(http.statusCode)")
                    }
                    let contentType = http.value(forHTTPHeaderField: "Content-Type")
                    return (data, contentType)
                }
                return (data, nil)
            } catch let error as AggregatorError {
                if case .articleSkip = error { throw error }   // 4xx: do not retry
                lastError = error
            } catch {
                lastError = error
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }
        throw lastError
    }
}
