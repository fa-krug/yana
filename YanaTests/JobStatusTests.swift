import Foundation
import Testing
@testable import Yana

@Suite("Job and run status wire shapes")
struct JobStatusTests {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: json.data(using: .utf8)!)
    }

    @Test func jobStatusDecodesARunningReloadJob() throws {
        let job: JobStatusResponse = try decode("""
        {"jobId":42,"runId":null,"kind":"article.reload","progress":55,"status":"running",
         "error":"","startedAt":"2026-09-01T10:00:00.000Z","finishedAt":null}
        """)
        #expect(job.jobId == 42)
        #expect(job.runId == nil)
        #expect(job.progress == 55)
        #expect(!job.isTerminal)
        #expect(!job.didSucceed)
    }

    @Test func jobStatusTreatsEveryTerminalStatusAsTerminalAndOnlyCompletedAsSuccess() throws {
        for status in ["completed", "failed", "cancelled"] {
            let job: JobStatusResponse = try decode("""
            {"jobId":1,"runId":null,"kind":"article.reload","progress":100,"status":"\(status)",
             "error":"","startedAt":null,"finishedAt":null}
            """)
            #expect(job.isTerminal)
            #expect(job.didSucceed == (status == "completed"))
        }
        for status in ["pending", "running", "cancelling", "something-new"] {
            let job: JobStatusResponse = try decode("""
            {"jobId":1,"runId":null,"kind":"article.reload","progress":0,"status":"\(status)",
             "error":"","startedAt":null,"finishedAt":null}
            """)
            #expect(!job.isTerminal)
        }
    }

    @Test func runStatusCarriesTheServerComputedPercentage() throws {
        let run: RunStatusResponse = try decode("""
        {"runId":5,"status":"running","progress":25,"totalJobs":4,"completedJobs":1,"failedJobs":0}
        """)
        #expect(run.progress == 25)
        #expect(!run.isTerminal)

        let done: RunStatusResponse = try decode("""
        {"runId":5,"status":"completed","progress":100,"totalJobs":4,"completedJobs":4,"failedJobs":0}
        """)
        #expect(done.isTerminal)
        #expect(done.didSucceed)
    }

    /// `isTerminal` used to be `!isRunning`, which read ANY unrecognized status -- e.g. a future
    /// `"pending"`/`"queued"` this build has never heard of -- as terminal-and-failed. It must
    /// instead degrade to "keep waiting", the same way `JobStatusResponse.isTerminal` already
    /// does for an unrecognized job status.
    @Test func runStatusTreatsAnUnrecognizedStatusAsNotTerminal() throws {
        let run: RunStatusResponse = try decode("""
        {"runId":5,"status":"something-new","progress":10,"totalJobs":4,"completedJobs":0,"failedJobs":0}
        """)
        #expect(!run.isTerminal)
        #expect(!run.didSucceed)
    }
}
