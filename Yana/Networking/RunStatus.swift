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
    /// A run is `running`, `completed` or `failed` server-side, so anything that is not still
    /// running has ended.
    var isTerminal: Bool { !isRunning }
    var didSucceed: Bool { status == "completed" }
}

/// `GET`/`PATCH /api/v1/reading-position`'s response shape -- shared by `SyncEngine`'s pull and
/// `ArticleActions`' push, which otherwise independently declared the identical struct. Also the
/// shape `JobEventPayload.readingPosition` mirrors (minus the nullability -- see its doc comment).
struct ReadingPositionWire: Decodable, Sendable {
    let articleId: Int?
    let updatedAt: Date?
}
