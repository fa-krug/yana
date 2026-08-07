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
