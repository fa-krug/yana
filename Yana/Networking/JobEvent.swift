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
