import Foundation

/// Async HTTP wrapper: browser-ish UA, timeout, retry with exponential backoff,
/// and `AggregatorError.articleSkip` on 4xx (mirrors the server's html_fetcher + ArticleSkipError).
enum HTTPClient {
    static let userAgent = "Mozilla/5.0 (compatible; YanaBot/1.0; +https://github.com/fa-krug/Yana)"

    /// Hard ceiling on a single response body. Untrusted feeds/images must not exhaust memory.
    static let maxResponseBytes = 25 * 1024 * 1024   // 25 MB

    /// Pure helper (unit-testable): true when the accumulated byte count exceeds the cap.
    static func exceedsCap(received: Int, cap: Int) -> Bool { received > cap }

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

    private static func send(_ request: URLRequest, maxAttempts: Int = 3) async throws
    -> (data: Data, contentType: String?) {
        var lastError: Error = AggregatorError.contentFetch("unknown")
        for attempt in 0..<maxAttempts {
            do {
                return try await performRequest(request)
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

    /// Perform a single request: stream the body under the size cap and map the HTTP status.
    private static func performRequest(_ request: URLRequest) async throws
    -> (data: Data, contentType: String?) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        // Cheap early-reject: if the server declares a body larger than the cap, fail before
        // streaming a single byte. (A server that lies/omits Content-Length is still bounded by
        // the streaming guard below — at the cost of per-byte iteration for in-cap bodies.)
        if response.expectedContentLength != NSURLSessionTransferSizeUnknown,
           exceedsCap(received: Int(response.expectedContentLength), cap: maxResponseBytes) {
            throw AggregatorError.contentFetch("declared response size exceeded \(maxResponseBytes) bytes")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if exceedsCap(received: data.count, cap: maxResponseBytes) {
                throw AggregatorError.contentFetch("response exceeded \(maxResponseBytes) bytes")
            }
        }
        guard let http = response as? HTTPURLResponse else { return (data, nil) }
        if (400..<500).contains(http.statusCode) {
            throw AggregatorError.articleSkip(statusCode: http.statusCode)
        }
        if http.statusCode >= 500 {
            throw AggregatorError.contentFetch("HTTP \(http.statusCode)")
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }
}
