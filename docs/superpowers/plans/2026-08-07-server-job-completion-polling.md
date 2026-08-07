# Server Job Completion Polling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two blind fixed-backoff polls in `UpdateAndSync` with real completion detection — "Update All" polls the server's actual run status (`GET /api/v1/runs/:id`) instead of guessing, and "Reload" waits for the server's SSE job-completion event (`GET /api/v1/jobs/events`) instead of re-fetching content on a fixed schedule with no idea whether the job finished.

**Architecture:** Two independent completion signals, because the two triggers are tracked differently server-side (confirmed by reading `yana-server` directly — see `docs/superpowers/specs/2026-08-05-server-api-client-rework-design.md:137-138` for the original intent this plan finally implements):
- `POST /aggregate` returns a `runId`; the run's status is queryable via `GET /api/v1/runs/:id` → `{ runId, status: "running"|"completed"|"failed", totalJobs, completedJobs, failedJobs }`. "Update All" polls this REST endpoint until `status != "running"`, then runs exactly one `SyncEngine.sync()`.
- `POST /articles/:id/reload` returns a `jobId`, but this job has `runId: null` — it is **not** part of a run, so `/runs/:id` cannot see it, and there is no `GET /jobs/:id`. The only place its completion surfaces is the per-user SSE stream `GET /api/v1/jobs/events`, which emits `event: job\ndata: {jobId, runId, kind, status, progress}` frames **only on terminal transition** (`status` one of `"completed"|"failed"|"cancelled"`). "Reload" connects to this stream and waits for a `job` event whose `jobId` matches, with a bounded timeout; if the stream never delivers a match (dropped connection, missed event — it's documented as best-effort), it falls back to exactly one direct content re-fetch, matching today's already-accepted "no guaranteed detection" behavior as a safety net rather than a primary mechanism.

**Tech Stack:** Swift 6, `URLSession.bytes(for:)` for the SSE stream (no third-party SSE library — the wire format is 3 field types and one blank-line frame terminator), Swift Testing (`import Testing`), the existing `MockURLProtocol` test double (works for `bytes(for:)` the same way it works for `data(for:)` — both ride the same `URLProtocol` loading system).

## Global Constraints

- Swift 6 strict concurrency; `@MainActor` where the codebase already uses it (`UpdateAndSync` is `@MainActor`).
- Every new type must be `Sendable` where it crosses an `await` boundary, matching `YanaAPIClient`'s existing pattern (`struct ... : Sendable`).
- No new user-facing strings are introduced by this plan (existing toasts in the three call sites are unchanged) — no `Localizable.xcstrings` entries needed.
- Wire field names must match `yana-server`'s `ApiEvent` union exactly (`/Users/skrug/PycharmProjects/yana-server/src/lib/api/events.ts:44-64`): `jobId`, `runId`, `kind`, `status`, `progress` for `job` events; `runId`, `status`, `totalJobs`, `completedJobs`, `failedJobs` for `run` events. `status` decodes as a plain `String` on both — the server itself does not expose it as a closed enum type (`status: string` in its own source), so this client mirrors that rather than inventing a `Decodable` enum that could fail to decode on a future server-added value.
- Terminal job statuses are exactly `"completed"`, `"failed"`, `"cancelled"` (confirmed from `yana-server`'s `publishJobOutcome()` call sites in `queue.ts`) — nothing else is ever emitted as an SSE `job` event.
- Run statuses are exactly `"running"`, `"completed"`, `"failed"` (confirmed from `yana-server`'s `schema/jobs.ts` default and `bumpRunCounters()` in `queue.ts`) — there is no `"pending"` state for a run.
- Run tests with: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/<SuiteName>`

---

### Task 1: SSE frame accumulator (pure parsing, no networking)

**Files:**
- Create: `Yana/Networking/SSEFrameAccumulator.swift`
- Test: `YanaTests/SSEFrameAccumulatorTests.swift`

**Interfaces:**
- Consumes: nothing (pure, self-contained).
- Produces: `struct SSEFrame: Equatable, Sendable { let event: String?; let data: String }` and `struct SSEFrameAccumulator { mutating func consume(line: String) -> SSEFrame? }` — later tasks feed it one line at a time from an SSE byte stream; it returns a completed frame exactly when a blank line closes one, `nil` otherwise.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import Yana

@Suite("SSEFrameAccumulator")
struct SSEFrameAccumulatorTests {
    @Test func emitsAFrameOnBlankLineWithEventAndData() {
        var accumulator = SSEFrameAccumulator()
        #expect(accumulator.consume(line: "event: job") == nil)
        #expect(accumulator.consume(line: #"data: {"jobId":1}"#) == nil)
        let frame = accumulator.consume(line: "")
        #expect(frame == SSEFrame(event: "job", data: #"{"jobId":1}"#))
    }

    @Test func joinsMultipleDataLinesWithNewlines() {
        var accumulator = SSEFrameAccumulator()
        _ = accumulator.consume(line: "event: run")
        _ = accumulator.consume(line: "data: line one")
        _ = accumulator.consume(line: "data: line two")
        let frame = accumulator.consume(line: "")
        #expect(frame == SSEFrame(event: "run", data: "line one\nline two"))
    }

    @Test func ignoresCommentLinesLikeThePingKeepAlive() {
        var accumulator = SSEFrameAccumulator()
        #expect(accumulator.consume(line: ": ping") == nil)
        // A comment-only "frame" (no data lines) produces no frame at its blank line.
        #expect(accumulator.consume(line: "") == nil)
    }

    @Test func aFrameWithNoEventFieldHasANilEventName() {
        var accumulator = SSEFrameAccumulator()
        _ = accumulator.consume(line: #"data: {"foo":true}"#)
        let frame = accumulator.consume(line: "")
        #expect(frame == SSEFrame(event: nil, data: #"{"foo":true}"#))
    }

    @Test func resetsStateAfterEmittingSoASecondFrameStartsClean() {
        var accumulator = SSEFrameAccumulator()
        _ = accumulator.consume(line: "event: job")
        _ = accumulator.consume(line: "data: first")
        _ = accumulator.consume(line: "")
        _ = accumulator.consume(line: "data: second")
        let frame = accumulator.consume(line: "")
        #expect(frame == SSEFrame(event: nil, data: "second"))
    }

    @Test func stripsExactlyOneLeadingSpaceAfterTheColon() {
        var accumulator = SSEFrameAccumulator()
        // SSE spec: at most one leading space after "field:" is stripped, not all whitespace.
        _ = accumulator.consume(line: "data:  two leading spaces")
        let frame = accumulator.consume(line: "")
        #expect(frame == SSEFrame(event: nil, data: " two leading spaces"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SSEFrameAccumulatorTests`
Expected: FAIL to build — `SSEFrame`/`SSEFrameAccumulator` do not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// One complete Server-Sent Events frame: an optional `event:` name and the (possibly
/// multi-line, newline-joined) `data:` payload. `yana-server`'s `/api/v1/jobs/events` sends
/// `event: job`/`event: run` frames plus bare `: ping` comment frames with no data at all.
struct SSEFrame: Equatable, Sendable {
    let event: String?
    let data: String
}

/// Feed this one already-newline-split line at a time (as delivered by
/// `URLSession.AsyncBytes.lines`). Per the SSE spec: a blank line terminates and emits the
/// current frame; a line starting with `:` is a comment (used by the server purely as a
/// keep-alive ping) and is ignored; `field: value` lines set that field, with exactly one
/// leading space after the colon stripped if present. A blank line with no `data:` line seen
/// (e.g. only a ping comment before it) emits no frame.
struct SSEFrameAccumulator {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> SSEFrame? {
        if line.isEmpty {
            defer { eventName = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return SSEFrame(event: eventName, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let field = String(line[line.startIndex..<colonIndex])
        var value = String(line[line.index(after: colonIndex)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/SSEFrameAccumulatorTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Yana/Networking/SSEFrameAccumulator.swift YanaTests/SSEFrameAccumulatorTests.swift
git commit -m "Add pure SSE frame accumulator for job-events parsing"
```

---

### Task 2: Job/run event wire types

**Files:**
- Create: `Yana/Networking/JobEvent.swift`
- Test: `YanaTests/JobEventTests.swift`

**Interfaces:**
- Consumes: `SSEFrame` from Task 1.
- Produces: `struct JobEventPayload: Decodable, Equatable, Sendable { let jobId: Int; let runId: Int?; let kind: String; let status: String; let progress: Double }` with `var isTerminal: Bool`; `struct RunEventPayload: Decodable, Equatable, Sendable { let runId: Int; let status: String; let totalJobs: Int; let completedJobs: Int; let failedJobs: Int }`; `enum JobEvent: Equatable, Sendable { case job(JobEventPayload); case run(RunEventPayload); static func decode(frame: SSEFrame) -> JobEvent? }`. Task 3 calls `JobEvent.decode(frame:)` on every accumulated frame.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Yana

@Suite("JobEvent")
struct JobEventTests {
    @Test func decodesAJobFrameIntoAJobEvent() {
        let frame = SSEFrame(event: "job", data: #"{"jobId":1,"runId":null,"kind":"article.reload","status":"completed","progress":1}"#)
        #expect(JobEvent.decode(frame: frame) == .job(
            JobEventPayload(jobId: 1, runId: nil, kind: "article.reload", status: "completed", progress: 1)
        ))
    }

    @Test func decodesARunFrameIntoARunEvent() {
        let frame = SSEFrame(event: "run", data: #"{"runId":5,"status":"running","totalJobs":3,"completedJobs":1,"failedJobs":0}"#)
        #expect(JobEvent.decode(frame: frame) == .run(
            RunEventPayload(runId: 5, status: "running", totalJobs: 3, completedJobs: 1, failedJobs: 0)
        ))
    }

    @Test func returnsNilForAFrameWithNoRecognizedEventName() {
        let frame = SSEFrame(event: nil, data: "irrelevant")
        #expect(JobEvent.decode(frame: frame) == nil)
    }

    @Test func returnsNilWhenDataDoesNotMatchTheExpectedShape() {
        let frame = SSEFrame(event: "job", data: "not json")
        #expect(JobEvent.decode(frame: frame) == nil)
    }

    @Test func terminalStatusesAreCompletedFailedAndCancelledOnly() {
        #expect(JobEventPayload(jobId: 1, runId: nil, kind: "x", status: "completed", progress: 1).isTerminal)
        #expect(JobEventPayload(jobId: 1, runId: nil, kind: "x", status: "failed", progress: 1).isTerminal)
        #expect(JobEventPayload(jobId: 1, runId: nil, kind: "x", status: "cancelled", progress: 1).isTerminal)
        #expect(!JobEventPayload(jobId: 1, runId: nil, kind: "x", status: "running", progress: 0.5).isTerminal)
        #expect(!JobEventPayload(jobId: 1, runId: nil, kind: "x", status: "pending", progress: 0).isTerminal)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/JobEventTests`
Expected: FAIL to build — none of these types exist yet.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Mirrors `yana-server`'s `ApiEvent` "job" variant exactly
/// (`src/lib/api/events.ts:44-64` in the `yana-server` repo). `status` is decoded as a plain
/// `String`, matching the server's own `status: string` field -- not a closed Swift enum -- so a
/// future server-added status value degrades to "not terminal, keep waiting" rather than a decode
/// failure that drops the whole event.
struct JobEventPayload: Decodable, Equatable, Sendable {
    let jobId: Int
    let runId: Int?
    let kind: String
    let status: String
    let progress: Double

    /// Confirmed against `yana-server`'s `publishJobOutcome()` call sites in `src/lib/jobs/queue.ts`:
    /// a `job` SSE event is only ever published on one of these three terminal transitions --
    /// there is no SSE event at all for "pending"/"running"/"cancelling".
    var isTerminal: Bool {
        status == "completed" || status == "failed" || status == "cancelled"
    }
}

/// Mirrors the `ApiEvent` "run" variant. `status` is one of `"running"`/`"completed"`/`"failed"`
/// server-side (confirmed via `schema/jobs.ts`'s default and `bumpRunCounters()` in `queue.ts`) --
/// there is no `"pending"` state for a run.
struct RunEventPayload: Decodable, Equatable, Sendable {
    let runId: Int
    let status: String
    let totalJobs: Int
    let completedJobs: Int
    let failedJobs: Int
}

enum JobEvent: Equatable, Sendable {
    case job(JobEventPayload)
    case run(RunEventPayload)

    static func decode(frame: SSEFrame) -> JobEvent? {
        guard let data = frame.data.data(using: .utf8) else { return nil }
        switch frame.event {
        case "job":
            guard let payload = try? JSONDecoder().decode(JobEventPayload.self, from: data) else { return nil }
            return .job(payload)
        case "run":
            guard let payload = try? JSONDecoder().decode(RunEventPayload.self, from: data) else { return nil }
            return .run(payload)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/JobEventTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Yana/Networking/JobEvent.swift YanaTests/JobEventTests.swift
git commit -m "Add job/run SSE event wire types"
```

---

### Task 3: `JobEventsClient` — the actual SSE network stream

**Files:**
- Create: `Yana/Networking/JobEventsClient.swift`
- Test: `YanaTests/JobEventsClientTests.swift`

**Interfaces:**
- Consumes: `YanaAPIClient` (its `baseURL`/`token`/`session` stored properties, already non-private per `Yana/Networking/YanaAPIClient.swift:5-14`), `SSEFrameAccumulator`/`SSEFrame` (Task 1), `JobEvent.decode(frame:)` (Task 2).
- Produces: `struct JobEventsClient: Sendable { let client: YanaAPIClient; func events() -> AsyncThrowingStream<JobEvent, Error> }`. Task 5 calls `JobEventsClient(client: client).events()` and iterates it with `for try await`.

- [ ] **Step 1: Write the failing test**

```swift
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
                + "event: run\ndata: {\"runId\":5,\"status\":\"completed\",\"totalJobs\":3,\"completedJobs\":3,\"failedJobs\":0}\n\n"
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
                .run(RunEventPayload(runId: 5, status: "completed", totalJobs: 3, completedJobs: 3, failedJobs: 0)),
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/JobEventsClientTests`
Expected: FAIL to build — `JobEventsClient` does not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
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
                    let (bytes, response) = try await client.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw YanaAPIClientError.transport
                    }
                    var accumulator = SSEFrameAccumulator()
                    for try await line in bytes.lines {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/JobEventsClientTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Yana/Networking/JobEventsClient.swift YanaTests/JobEventsClientTests.swift
git commit -m "Add JobEventsClient to stream /api/v1/jobs/events"
```

---

### Task 4: `RunStatus` wire type, and `ArticleActions.reload` returns its `jobId`

**Files:**
- Modify: `Yana/Networking/RunStatus.swift` (create)
- Modify: `Yana/Services/ArticleActions.swift:35-37`
- Modify: `YanaTests/ArticleActionsTests.swift:28-34` (existing `reloadPostsAndSucceedsOn202` test)

**Interfaces:**
- Consumes: `YanaAPIClient.get` (existing, generic).
- Produces: `struct RunStatusResponse: Decodable, Equatable, Sendable { let runId: Int; let status: String; let totalJobs: Int; let completedJobs: Int; let failedJobs: Int }`; `ArticleActions.reload(articleServerID:) async throws -> Int` (now returns the `jobId` instead of discarding it). Task 5's `UpdateAndSync.pollForReloadedContent` takes this `jobId` as a parameter; Task 6's call-site updates capture `reload`'s return value.

- [ ] **Step 1: Write the failing test (updates the existing reload test to assert the returned jobId)**

Replace the existing `reloadPostsAndSucceedsOn202` test in `YanaTests/ArticleActionsTests.swift` with:

```swift
    @Test func reloadPostsAndReturnsTheJobId() async throws {
        try await MockURLProtocol.lock.withLock {
            let client = stubClient(pathsToResponses: [
                "POST /api/v1/articles/100/reload": (#"{"jobId":1}"#.data(using: .utf8)!, 202)
            ])
            let actions = ArticleActions(client: client)
            let jobID = try await actions.reload(articleServerID: 100)
            #expect(jobID == 1)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleActionsTests`
Expected: FAIL — `reload` currently returns `Void`, so `let jobID = try await actions.reload(...)` does not compile.

- [ ] **Step 3: Write the implementation**

In `Yana/Networking/RunStatus.swift`:

```swift
import Foundation

/// `GET /api/v1/runs/:id`'s response shape (`yana-server`'s `src/app/api/v1/runs/[id]/route.ts`).
/// `status` is one of `"running"`/`"completed"`/`"failed"` server-side, decoded as a plain
/// `String` to match the server's own `status: string` column rather than a closed Swift enum.
struct RunStatusResponse: Decodable, Equatable, Sendable {
    let runId: Int
    let status: String
    let totalJobs: Int
    let completedJobs: Int
    let failedJobs: Int

    var isRunning: Bool { status == "running" }
}
```

In `Yana/Services/ArticleActions.swift`, change:

```swift
    func reload(articleServerID: Int) async throws {
        let _: ReloadResponse = try await client.post("/api/v1/articles/\(articleServerID)/reload")
    }
```

to:

```swift
    /// Returns the server's `jobId` for this reload -- `UpdateAndSync.pollForReloadedContent`
    /// needs it to pick this job's own completion event out of the shared `/jobs/events` stream
    /// (every reload/aggregate job for this user is multiplexed onto that one stream).
    @discardableResult
    func reload(articleServerID: Int) async throws -> Int {
        let response: ReloadResponse = try await client.post("/api/v1/articles/\(articleServerID)/reload")
        return response.jobId
    }
```

Also update the doc comment block above the class (lines 10-18) to mention that `reload`'s ack now carries a usable `jobId`:

```swift
/// Thin façade over the article-mutating parts of the API, so UI code doesn't construct
/// `YanaAPIClient` calls inline. Read paths (sync, content, feeds) live in `SyncEngine` instead --
/// this is specifically the user-initiated write/trigger surface.
///
/// Every method here only sends a request and decodes its ack -- it never touches the local
/// SwiftData mirror itself. `setStarred`'s ack does carry the new value back, but callers still
/// own writing it locally (this type has no `ModelContext`); `reload`/`updateAll` only trigger
/// server-side work, returning a job/run id callers hand to `UpdateAndSync` to actually observe
/// completion and pull results down -- neither ack is new content itself.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ArticleActionsTests`
Expected: PASS. Note this will also show 3 build errors at this point in `Yana/Reader/ReaderHostView.swift`, `Yana/Reader/Mac/TimelineModel.swift`, and `Yana/Views/Config/ArticleListView.swift` — those callers still call `reload` without capturing a return value, which is fine for `@discardableResult`, so they still compile. (They start failing only after Task 5 changes `pollForReloadedContent`'s signature to require a `jobId` — Task 6 fixes those together.)

- [ ] **Step 5: Commit**

```bash
git add Yana/Networking/RunStatus.swift Yana/Services/ArticleActions.swift YanaTests/ArticleActionsTests.swift
git commit -m "ArticleActions.reload returns its jobId; add RunStatusResponse wire type"
```

---

### Task 5: Rewrite `UpdateAndSync` for real completion detection

**Files:**
- Modify: `Yana/Services/UpdateAndSync.swift` (full rewrite of both public functions)
- Test: `YanaTests/UpdateAndSyncTests.swift` (create)

**Interfaces:**
- Consumes: `JobEventsClient`/`JobEvent`/`JobEventPayload` (Task 3/2), `RunStatusResponse` (Task 4), `SyncEngine`/`SyncResult` (existing), `SyncWriter`/`WireDocument`/`OffMainActor` (existing, same as today's `pollForReloadedContent`).
- Produces:
  - `static func pollForFreshContent(runId: Int, container: ModelContainer, client: YanaAPIClient, settings: AppSettings, pollInterval: Duration = .seconds(1), maxAttempts: Int = 30) async -> SyncResult`
  - `static func pollForReloadedContent(jobId: Int, articleServerID: Int, container: ModelContainer, client: YanaAPIClient, eventTimeout: Duration = .seconds(30)) async -> Bool`

  Both gained a leading id parameter (`runId`/`jobId`) versus today's signatures, and `pollForFreshContent` gained two optional tuning parameters with production defaults — tests override them to keep runtime fast. Task 6 updates the three call sites to pass the new leading parameters (which they already have on hand: `updateAll()`'s return value and `reload()`'s return value from Task 4) and to compile against the new signatures.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@Suite("UpdateAndSync", .serialized)
@MainActor
struct UpdateAndSyncTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings(container: ModelContainer) -> AppSettings {
        let settings = AppSettings()
        container.mainContext.insert(settings)
        return settings
    }

    private func stubClient(pathsToResponses: [String: (Data, Int)]) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let (data, status) = pathsToResponses[key] ?? (Data(), 404)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    // MARK: - pollForFreshContent

    @Test func pollForFreshContentWaitsUntilTheRunIsNoLongerRunningThenSyncsOnce() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings(container: container)
            var runStatusCallCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/runs/5" {
                    runStatusCallCount += 1
                    let status = runStatusCallCount < 3 ? "running" : "completed"
                    let body = #"{"runId":5,"status":"\#(status)","totalJobs":1,"completedJobs":0,"failedJobs":0}"#
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, body.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/sync" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/feeds" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let result = await UpdateAndSync.pollForFreshContent(
                runId: 5, container: container, client: client, settings: settings, pollInterval: .milliseconds(10)
            )

            #expect(runStatusCallCount == 3)
            #expect(result == SyncResult(newCount: 0, updatedCount: 0, removedCount: 0))
        }
    }

    @Test func pollForFreshContentGivesUpAfterMaxAttemptsAndStillSyncsOnce() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings(container: container)
            var syncCallCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/runs/5" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"runId":5,"status":"running","totalJobs":1,"completedJobs":0,"failedJobs":0}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/sync" {
                    syncCallCount += 1
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/feeds" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            _ = await UpdateAndSync.pollForFreshContent(
                runId: 5, container: container, client: client, settings: settings,
                pollInterval: .milliseconds(1), maxAttempts: 3
            )

            #expect(syncCallCount == 1)
        }
    }

    // MARK: - pollForReloadedContent

    @Test func pollForReloadedContentFetchesContentWhenTheMatchingJobCompletes() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", aggregator: "feed_content", identifier: "f1",
                             enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                        date: .now, author: nil, icon: nil, read: false, starred: false,
                                        createdAt: .now, updatedAt: .now)
            ])

            let sseBody = "event: job\ndata: {\"jobId\":42,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
            let contentBody = #"{"version":1,"blocks":[]}"#
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/jobs/events" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, sseBody.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/100/content" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, contentBody.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: 42, articleServerID: 100, container: container, client: client
            )

            #expect(applied)
        }
    }

    @Test func pollForReloadedContentReturnsFalseWithoutFetchingWhenTheJobFails() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            var contentFetchCount = 0
            let sseBody = "event: job\ndata: {\"jobId\":42,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"failed\",\"progress\":1}\n\n"
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/jobs/events" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, sseBody.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/100/content" {
                    contentFetchCount += 1
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"version":1,"blocks":[]}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: 42, articleServerID: 100, container: container, client: client
            )

            #expect(!applied)
            #expect(contentFetchCount == 0)
        }
    }

    @Test func pollForReloadedContentFallsBackToADirectFetchWhenNoMatchingEventArrivesInTime() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", aggregator: "feed_content", identifier: "f1",
                             enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                        date: .now, author: nil, icon: nil, read: false, starred: false,
                                        createdAt: .now, updatedAt: .now)
            ])

            // The SSE stream reports a *different* job's completion, never job 42's -- it then
            // ends (as it does in this mock, which delivers one shot and closes), simulating a
            // dropped connection or a missed event.
            let sseBody = "event: job\ndata: {\"jobId\":99,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
            let contentBody = #"{"version":1,"blocks":[]}"#
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/jobs/events" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, sseBody.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/100/content" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, contentBody.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: 42, articleServerID: 100, container: container, client: client, eventTimeout: .milliseconds(50)
            )

            #expect(applied)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UpdateAndSyncTests`
Expected: FAIL to build — current `pollForFreshContent`/`pollForReloadedContent` don't take a leading `runId`/`jobId`, `pollInterval`, `maxAttempts`, or `eventTimeout` parameter.

- [ ] **Step 3: Write the implementation**

Replace the full contents of `Yana/Services/UpdateAndSync.swift` with:

```swift
import Foundation
import SwiftData

/// Coordinates a server-triggered write (`ArticleActions.reload`/`updateAll`) with observing its
/// actual completion and pulling the result back down. Both triggers only ack that the server
/// *started* work; this type is what turns that ack into "the work is done, here's the outcome."
///
/// The two triggers are tracked completely differently server-side (confirmed by reading
/// `yana-server` directly -- see `docs/superpowers/specs/2026-08-05-server-api-client-rework-design.md:137-138`
/// for the intent this file implements):
/// - `updateAll()`'s `POST /aggregate` returns a `runId` that IS queryable via
///   `GET /api/v1/runs/:id` (`RunStatusResponse`) -- `pollForFreshContent` polls that REST
///   endpoint until the run is no longer `"running"`, then syncs exactly once.
/// - `reload()`'s `POST /articles/:id/reload` returns a `jobId` for a job with `runId: null` --
///   it is NOT part of a run, so `/runs/:id` can never see it, and there is no `GET /jobs/:id`.
///   The only place its completion surfaces is the per-user SSE stream `GET /api/v1/jobs/events`
///   (`JobEventsClient`), which emits a terminal `job` event exactly once. That stream is
///   documented server-side as best-effort, so `pollForReloadedContent` falls back to a single
///   direct content re-fetch if no matching terminal event arrives within `eventTimeout`.
@MainActor
enum UpdateAndSync {
    /// Polls `GET /api/v1/runs/:id` until the run's status is no longer `"running"` (or attempts
    /// run out), then runs `SyncEngine.sync()` exactly once to pull in whatever the run produced.
    /// Cooperatively cancellable: bails immediately once the enclosing `Task` is cancelled.
    @discardableResult
    static func pollForFreshContent(
        runId: Int, container: ModelContainer, client: YanaAPIClient, settings: AppSettings,
        pollInterval: Duration = .seconds(1), maxAttempts: Int = 30
    ) async -> SyncResult {
        await waitForRunToFinish(runId: runId, client: client, pollInterval: pollInterval, maxAttempts: maxAttempts)
        guard !Task.isCancelled else {
            return SyncResult(newCount: 0, updatedCount: 0, removedCount: 0)
        }
        let engine = SyncEngine(container: container, client: client, settings: settings)
        return (try? await engine.sync()) ?? SyncResult(newCount: 0, updatedCount: 0, removedCount: 0)
    }

    private static func waitForRunToFinish(
        runId: Int, client: YanaAPIClient, pollInterval: Duration, maxAttempts: Int
    ) async {
        for _ in 0..<maxAttempts {
            if Task.isCancelled { return }
            guard let status: RunStatusResponse = try? await client.get("/api/v1/runs/\(runId)") else { return }
            if !status.isRunning { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Waits for `/api/v1/jobs/events` to report this exact `jobId` reaching a terminal state,
    /// then -- only on `"completed"` -- re-fetches and applies that one article's content
    /// directly, bypassing `SyncEngine`'s generic `hasContent`-gated backfill entirely (an earlier
    /// version of this code went through that backfill, resetting `hasContent = false` first, and
    /// that is actively wrong: a premature backfill fetch racing the poll sets `hasContent = true`
    /// and permanently blocks any later retry, since nothing else ever resets it). If the job
    /// reports `"failed"`/`"cancelled"`, there is nothing new to fetch, so this returns `false`
    /// without a network call. If no matching terminal event arrives within `eventTimeout` (a
    /// dropped SSE connection, or the event simply being missed -- the stream is best-effort),
    /// this falls back to exactly one direct content fetch, matching what this method has always
    /// done as its fallback path.
    @discardableResult
    static func pollForReloadedContent(
        jobId: Int, articleServerID: Int, container: ModelContainer, client: YanaAPIClient,
        eventTimeout: Duration = .seconds(30)
    ) async -> Bool {
        switch await waitForReloadJobOutcome(jobId: jobId, client: client, eventTimeout: eventTimeout) {
        case .some(false):
            return false
        case .some(true), .none:
            return await fetchAndApplyContent(articleServerID: articleServerID, container: container, client: client)
        }
    }

    /// `true` = the matching job completed; `false` = it failed/was cancelled; `nil` = no matching
    /// terminal event arrived before `eventTimeout` (dropped connection, missed event, or the
    /// stream simply ended without ever mentioning this job).
    private static func waitForReloadJobOutcome(
        jobId: Int, client: YanaAPIClient, eventTimeout: Duration
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                var iterator = JobEventsClient(client: client).events().makeAsyncIterator()
                while let event = try? await iterator.next() {
                    if case let .job(payload) = event, payload.jobId == jobId, payload.isTerminal {
                        return payload.status == "completed"
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: eventTimeout)
                return nil
            }
            defer { group.cancelAll() }
            for await result in group {
                return result
            }
            return nil
        }
    }

    private static func fetchAndApplyContent(
        articleServerID: Int, container: ModelContainer, client: YanaAPIClient
    ) async -> Bool {
        guard let document: WireDocument = try? await client.get(
            "/api/v1/articles/\(articleServerID)/content"
        ) else { return false }
        // `SyncWriter` is a `@ModelActor` -- per this codebase's rule, every call into one from a
        // `@MainActor` context (this enum) must be hopped off-main via `OffMainActor.run`, or the
        // write runs inline on the calling (main) thread.
        let writer = SyncWriter(modelContainer: container)
        return await OffMainActor.run {
            await writer.applyContent(articleServerID: articleServerID, document: document)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UpdateAndSyncTests`
Expected: PASS (5 tests). Note the three call sites in `ReaderHostView.swift`/`TimelineModel.swift`/`ArticleListView.swift` will now fail to build (wrong argument labels/missing `runId`/`jobId`) — Task 6 fixes them next; this task's own test target run above only exercises `YanaTests/UpdateAndSyncTests`, which does not depend on those app-target files compiling cleanly against the *new* call shape (they still reference the old one), so isolate this run to that one suite as shown.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/UpdateAndSync.swift YanaTests/UpdateAndSyncTests.swift
git commit -m "UpdateAndSync: poll real run/job status instead of a blind fixed backoff"
```

---

### Task 6: Update the three call sites, then run the full test suite

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift:382-385` and `:422-425`
- Modify: `Yana/Reader/Mac/TimelineModel.swift:271-274` and `:307-310`
- Modify: `Yana/Views/Config/ArticleListView.swift:112-115`

**Interfaces:**
- Consumes: `ArticleActions.reload(articleServerID:) -> Int` (Task 4), `ArticleActions.updateAll() -> Int` (already existed, unchanged), `UpdateAndSync.pollForReloadedContent(jobId:articleServerID:container:client:eventTimeout:)` and `UpdateAndSync.pollForFreshContent(runId:container:client:settings:pollInterval:maxAttempts:)` (Task 5).
- Produces: nothing new — this task only makes the app target compile again against Task 5's new signatures, using each site's own tuning defaults (no override needed; production code always uses the default `eventTimeout`/`pollInterval`/`maxAttempts`).

- [ ] **Step 1: There is no new test to write for this task** — it is a mechanical call-site update with no new behavior of its own; Task 5's tests already cover `UpdateAndSync`'s logic and Task 4's test already covers `reload`'s new return value. This task's own verification is "the whole app target builds and every existing test still passes" (Step 4 below).

- [ ] **Step 2: N/A** (no new failing test to run first — confirm instead that the app target currently fails to build)

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: FAIL — the three call sites below still call the old signatures.

- [ ] **Step 3: Update each call site**

In `Yana/Reader/ReaderHostView.swift`, inside `forceUpdateArticle` (around line 382):

```swift
                try await ArticleActions(client: client).reload(articleServerID: serverID)
                guard !Task.isCancelled else { return }
                let applied = await UpdateAndSync.pollForReloadedContent(
                    articleServerID: serverID, container: modelContext.container, client: client
                )
```

becomes:

```swift
                let jobId = try await ArticleActions(client: client).reload(articleServerID: serverID)
                guard !Task.isCancelled else { return }
                let applied = await UpdateAndSync.pollForReloadedContent(
                    jobId: jobId, articleServerID: serverID, container: modelContext.container, client: client
                )
```

and inside `triggerRefresh` (around line 422):

```swift
                try await ArticleActions(client: client).updateAll()
                guard !Task.isCancelled else { return }
                let result = await UpdateAndSync.pollForFreshContent(
                    container: modelContext.container, client: client, settings: settings
                )
```

becomes:

```swift
                let runId = try await ArticleActions(client: client).updateAll()
                guard !Task.isCancelled else { return }
                let result = await UpdateAndSync.pollForFreshContent(
                    runId: runId, container: modelContext.container, client: client, settings: settings
                )
```

In `Yana/Reader/Mac/TimelineModel.swift`, apply the identical two changes (same variable names, same surrounding code) at its `forceUpdateArticle` (around line 271) and `triggerRefresh` (around line 307):

```swift
                let jobId = try await ArticleActions(client: client).reload(articleServerID: serverID)
                guard !Task.isCancelled else { return }
                let applied = await UpdateAndSync.pollForReloadedContent(
                    jobId: jobId, articleServerID: serverID, container: modelContext.container, client: client
                )
```

```swift
                let runId = try await ArticleActions(client: client).updateAll()
                guard !Task.isCancelled else { return }
                let result = await UpdateAndSync.pollForFreshContent(
                    runId: runId, container: modelContext.container, client: client, settings: self.settings
                )
```

In `Yana/Views/Config/ArticleListView.swift`, inside the swipe action (around line 112):

```swift
                            try await ArticleActions(client: client).reload(articleServerID: serverID)
                            guard !Task.isCancelled else { return }
                            // See `UpdateAndSync.pollForReloadedContent`'s doc comment: this
                            // deliberately re-fetches this one article's content directly rather
                            // than going through `SyncEngine`'s generic `hasContent`-gated
                            // backfill, which a premature fetch during the poll window could
                            // permanently lock out of any later retry.
                            await UpdateAndSync.pollForReloadedContent(
                                articleServerID: serverID, container: modelContext.container, client: client
                            )
```

becomes:

```swift
                            let jobId = try await ArticleActions(client: client).reload(articleServerID: serverID)
                            guard !Task.isCancelled else { return }
                            // See `UpdateAndSync.pollForReloadedContent`'s doc comment: this
                            // deliberately re-fetches this one article's content directly rather
                            // than going through `SyncEngine`'s generic `hasContent`-gated
                            // backfill, which a premature fetch during the poll window could
                            // permanently lock out of any later retry.
                            await UpdateAndSync.pollForReloadedContent(
                                jobId: jobId, articleServerID: serverID, container: modelContext.container, client: client
                            )
```

- [ ] **Step 4: Build and run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass, including the new `SSEFrameAccumulatorTests`, `JobEventTests`, `JobEventsClientTests`, `UpdateAndSyncTests`, and the updated `ArticleActionsTests`.

- [ ] **Step 5: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift Yana/Reader/Mac/TimelineModel.swift Yana/Views/Config/ArticleListView.swift
git commit -m "Update reload/update-all call sites for real job/run completion polling"
```

---

## Self-Review

**Spec coverage:**
- "Update All" polls real run status (`GET /api/v1/runs/:id`) instead of blindly re-syncing on a fixed schedule → Task 5 (`pollForFreshContent`/`waitForRunToFinish`), wired up in Task 6.
- "Reload" waits for the server's actual job-completion signal (`GET /api/v1/jobs/events`, since no REST job-status-by-id endpoint exists) instead of blindly re-fetching content on a fixed schedule → Task 5 (`pollForReloadedContent`/`waitForReloadJobOutcome`), wired up in Task 6.
- `reload()` needed to start returning its `jobId` so the above has something to correlate against → Task 4.
- The still-needed fallback for a dropped/missed SSE event (since the stream is server-documented as best-effort) → Task 5's `.none` case in `pollForReloadedContent`, tested in Task 5's `pollForReloadedContentFallsBackToADirectFetchWhenNoMatchingEventArrivesInTime`.
- All three real call sites (iOS reader, Mac reader, iOS article list swipe) updated → Task 6.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" placeholders — every step has literal, complete code, including full test bodies.

**Type consistency:** `SSEFrame` (Task 1) is consumed identically by `JobEvent.decode(frame:)` (Task 2) and produced identically by `SSEFrameAccumulator.consume(line:)` (Task 1). `JobEvent`/`JobEventPayload`/`RunEventPayload` (Task 2) are consumed identically by `JobEventsClient.events()` (Task 3) and by `UpdateAndSync.waitForReloadJobOutcome` (Task 5). `RunStatusResponse` (Task 4) is consumed identically by `UpdateAndSync.waitForRunToFinish` (Task 5). `ArticleActions.reload`'s new `Int` return (Task 4) matches the `jobId` parameter added to `UpdateAndSync.pollForReloadedContent` (Task 5) and the call-site captures in Task 6. `ArticleActions.updateAll`'s existing `Int` return matches the `runId` parameter added to `UpdateAndSync.pollForFreshContent` (Task 5) and the call-site captures in Task 6.
