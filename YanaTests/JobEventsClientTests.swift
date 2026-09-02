import Foundation
import Testing
@testable import Yana

@Suite("JobEventsClient", .serialized)
struct JobEventsClientTests {
    // Every test wraps its whole body in `MockURLProtocol.lock.withLock` -- see
    // `YanaAPIClientTests.swift` for why this is required across suites sharing the static stub.

    @Test func decodesJobAndRunFramesFromTheStream() async throws {
        try await MockURLProtocol.lock.withLock {
            let sseBody = "event: job\ndata: {\"jobId\":1,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
                + ": ping\n\n"
                + "event: run\ndata: {\"runId\":5,\"status\":\"completed\",\"progress\":100,\"totalJobs\":3,\"completedJobs\":3,\"failedJobs\":0}\n\n"
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
                return (response, sseBody.data(using: .utf8)!)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            var events: [JobEvent] = []
            for try await event in JobEventsClient(client: client).events() {
                events.append(event)
            }

            #expect(events == [
                .job(JobEventPayload(jobId: 1, runId: nil, kind: "article.reload", status: "completed", progress: 1)),
                .run(RunEventPayload(runId: 5, status: "completed", progress: 100, totalJobs: 3, completedJobs: 3, failedJobs: 0)),
            ])
        }
    }

    @Test func attachesTheBearerTokenToTheEventsRequest() async throws {
        try await MockURLProtocol.lock.withLock {
            var capturedAuth: String?
            var capturedPath: String?
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                capturedPath = request.url!.path
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "abc123", session: URLSession(configuration: config))
            for try await _ in JobEventsClient(client: client).events() {}
            #expect(capturedAuth == "Bearer abc123")
            #expect(capturedPath == "/api/v1/jobs/events")
        }
    }

    @Test func throwsOnANon2xxResponse() async throws {
        try await MockURLProtocol.lock.withLock {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
            await #expect(throws: YanaAPIClientError.transport) {
                for try await _ in JobEventsClient(client: client).events() {}
            }
        }
    }

    @Test func cancelsTheUnderlyingTaskOnEarlyTermination() async throws {
        try await MockURLProtocol.lock.withLock {
            let sseBody = "event: job\ndata: {\"jobId\":1,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
                + "event: job\ndata: {\"jobId\":2,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
                + "event: job\ndata: {\"jobId\":3,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
                return (response, sseBody.data(using: .utf8)!)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            var eventCount = 0
            final class TerminationFlag: @unchecked Sendable {
                var terminated = false
            }
            let flag = TerminationFlag()
            do {
                for try await _ in JobEventsClient(client: client).events(didTerminate: { flag.terminated = true }) {
                    eventCount += 1
                    if eventCount >= 1 {
                        break  // Early termination after first event
                    }
                }
            }

            #expect(eventCount == 1)
            #expect(flag.terminated == true)
        }
    }
}
