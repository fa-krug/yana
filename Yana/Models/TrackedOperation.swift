import Foundation

/// One server-side operation this device triggered and is waiting on.
///
/// Persisted (`AppSettings.trackedOperations`) rather than held in memory, because the whole point
/// is that the wait outlives the view that started it and, if the app is killed, the process too:
/// on the next launch `OperationMonitor.resume()` reads these back and picks the same monitoring
/// up. A record is written the moment the triggering POST acks with an id, and removed only once a
/// terminal status has been observed and its follow-up work applied.
struct TrackedOperation: Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        /// `POST /api/v1/articles/:id/reload`. `id` is the job id; the article is carried
        /// separately because the job row does not name it in a form this client reads.
        case reloadArticle(serverID: Int)
        /// `POST /api/v1/aggregate`. `id` is the run id.
        case updateAll
    }

    let kind: Kind
    /// The job id for `.reloadArticle`, the run id for `.updateAll` -- the two live in different
    /// server-side tables and are polled through different routes, so `kind` alone says which.
    let id: Int
    let startedAt: Date

    /// A key that is unique across BOTH server-side id spaces. `id` alone is not: it is a job id
    /// for `.reloadArticle` and a run id for `.updateAll`, drawn from two different tables whose
    /// ids collide freely, so keying anything by `id` alone would confuse a run with a
    /// same-numbered job.
    var monitorKey: String {
        switch kind {
        case .reloadArticle: "job-\(id)"
        case .updateAll: "run-\(id)"
        }
    }

    /// The server web UI's jobs list (`src/app/(app)/jobs/page.tsx` in `yana-server`). This is
    /// where a progress indicator lands when there is no single job to show -- an "Update All"
    /// run, or a busy state with no tracked operation behind it at all.
    static let jobsPagePath = "/jobs"

    /// Where the server's web UI shows this operation, relative to the server base URL, for
    /// `ManagementWebView` to open when the user taps the progress indicator.
    ///
    /// A reload is one job with its own detail page (`/jobs/:id`, with the job's log lines and
    /// cancel action). A run has no page of its own in the server UI -- it is only visible as the
    /// batch of jobs it enqueued, so it lands on the jobs list, where those jobs sit at the top.
    var serverPagePath: String {
        switch kind {
        case .reloadArticle: "\(Self.jobsPagePath)/\(id)"
        case .updateAll: Self.jobsPagePath
        }
    }
}
