import Foundation

/// Streams `GET /api/v1/jobs/events` -- `yana-server`'s per-user SSE feed of job/run progress and
/// completion events (`src/app/api/v1/jobs/events/route.ts` in the `yana-server` repo).
///
/// The connection is explicitly documented server-side as best-effort -- a dropped connection
/// loses nothing but low-latency notification -- so nothing may depend on an event arriving.
/// `OperationMonitor` accordingly uses this feed **only to learn a percentage sooner than its next
/// poll would**, never to decide an outcome: what ends a wait is polling the durable
/// `GET /api/v1/jobs/:id` / `GET /api/v1/runs/:id` row until it reports a terminal status. A
/// standalone `article.reload` job has `runId: null` and so is invisible to the runs route, but
/// the jobs route sees it, which is why no timeout-based fallback is needed here any more.
struct JobEventsClient: Sendable {
    let client: YanaAPIClient

    func events(didTerminate: (@Sendable () -> Void)? = nil) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: client.baseURL.appendingPathComponent("/api/v1/jobs/events"))
                    request.setValue("Bearer \(client.token)", forHTTPHeaderField: "Authorization")
                    let (bytes, response) = try await client.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw YanaAPIClientError.transport
                    }
                    var accumulator = SSEFrameAccumulator()
                    var lineBuffer = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
                            lineBuffer.removeAll(keepingCapacity: true)
                            if let frame = accumulator.consume(line: line), let event = JobEvent.decode(frame: frame) {
                                continuation.yield(event)
                            }
                        } else {
                            lineBuffer.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                didTerminate?()
            }
        }
    }
}
