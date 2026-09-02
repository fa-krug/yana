import Foundation

/// `GET /api/v1/jobs/:id`'s response shape (`yana-server`'s
/// `src/app/api/v1/jobs/[id]/route.ts`). This is the durable state a standalone `article.reload`
/// job leaves behind: its `runId` is `null`, so `/runs/:id` can never see it, and its single
/// terminal SSE event is unrecoverable once missed. Being able to ask this row again later is
/// what lets a relaunched app find out how its reload ended.
///
/// `progress` is the progress signal, 0-100, shown verbatim. `status` is decoded as a plain
/// `String` to match the server's own `status` column, so a status this build has never heard of
/// degrades to "not terminal, keep waiting" instead of failing to decode.
///
/// `startedAt`/`finishedAt` are deliberately `String?`, not `Date?`: the server writes them with
/// `toISOString()`, which includes fractional seconds, and `JSONDecoder`'s `.iso8601` strategy
/// (what `YanaAPIClient` configures) rejects those. Nothing in this app reads these two fields, so
/// carrying them as opaque strings keeps the whole response decodable instead of trading a
/// feature nobody uses for a decode failure on every poll.
struct JobStatusResponse: Decodable, Equatable, Sendable {
    let jobId: Int
    let runId: Int?
    let kind: String
    let progress: Int
    let status: String
    let error: String
    let startedAt: String?
    let finishedAt: String?

    /// The work has ended, whatever the result. The only thing that ends monitoring.
    var isTerminal: Bool {
        status == "completed" || status == "failed" || status == "cancelled"
    }

    var didSucceed: Bool { status == "completed" }
}
