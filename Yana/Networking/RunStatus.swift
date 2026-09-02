import Foundation

/// `GET /api/v1/runs/:id`'s response shape (`yana-server`'s `src/app/api/v1/runs/[id]/route.ts`).
/// `status` is one of `"running"`/`"completed"`/`"failed"` server-side, decoded as a plain
/// `String` to match the server's own `status: string` column rather than a closed Swift enum.
struct RunStatusResponse: Decodable, Equatable, Sendable {
    let runId: Int
    let status: String
    /// The server's own completion percentage for this run (0-100), computed from its counters so
    /// every client shows the same number. Displayed verbatim.
    let progress: Int
    let totalJobs: Int
    let completedJobs: Int
    let failedJobs: Int

    var isRunning: Bool { status == "running" }
    /// Terminal only for the known terminal values -- symmetrical with `JobStatusResponse
    /// .isTerminal`. This used to be `!isRunning`, which read ANY unrecognized status (e.g. a
    /// future `"pending"`/`"queued"` this build has never heard of) as terminal-and-failed,
    /// turning an unknown-but-benign status into an immediate spurious "could not update" toast
    /// instead of just continuing to poll.
    var isTerminal: Bool { status == "completed" || status == "failed" }
    var didSucceed: Bool { status == "completed" }
}

/// `GET`/`PATCH /api/v1/reading-position`'s response shape -- shared by `SyncEngine`'s pull and
/// `ArticleActions`' push, which otherwise independently declared the identical struct. Also the
/// shape `JobEventPayload.readingPosition` mirrors (minus the nullability -- see its doc comment).
struct ReadingPositionWire: Decodable, Sendable {
    let articleId: Int?
    let updatedAt: Date?
}
