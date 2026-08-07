import Foundation

/// Streams `GET /api/v1/jobs/events` -- `yana-server`'s per-user SSE feed of job/run completion
/// events (`src/app/api/v1/jobs/events/route.ts` in the `yana-server` repo). This is the *only*
/// way to observe a standalone `article.reload` job finishing: that job has `runId: null`, so it
/// is invisible to `GET /api/v1/runs/:id`, and there is no `GET /api/v1/jobs/:id`.
///
/// The connection is explicitly documented server-side as best-effort -- a dropped connection
/// loses nothing but low-latency notification. Callers must have their own fallback for "the
/// stream ended (or errored) with no matching event," which `UpdateAndSync.pollForReloadedContent`
/// does by falling back to a direct content re-fetch.
struct JobEventsClient: Sendable {
    let client: YanaAPIClient

    func events() -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: client.baseURL.appendingPathComponent("/api/v1/jobs/events"))
                    request.setValue("Bearer \(client.token)", forHTTPHeaderField: "Authorization")
                    let (data, response) = try await client.session.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw YanaAPIClientError.transport
                    }
                    let content = String(data: data, encoding: .utf8) ?? ""
                    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    var accumulator = SSEFrameAccumulator()
                    for line in lines {
                        if let frame = accumulator.consume(line: line), let event = JobEvent.decode(frame: frame) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
