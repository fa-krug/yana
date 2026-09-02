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
        let frame = SSEFrame(event: "run", data: #"{"runId":5,"status":"running","progress":33,"totalJobs":3,"completedJobs":1,"failedJobs":0}"#)
        #expect(JobEvent.decode(frame: frame) == .run(
            RunEventPayload(runId: 5, status: "running", progress: 33, totalJobs: 3, completedJobs: 1, failedJobs: 0)
        ))
    }

    @Test func decodesAReadingPositionFrameIntoAReadingPositionEvent() {
        let frame = SSEFrame(event: "readingPosition", data: #"{"articleId":7,"updatedAt":"2026-08-12T10:00:00.000Z"}"#)
        #expect(JobEvent.decode(frame: frame) == .readingPosition(
            ReadingPositionEventPayload(articleId: 7, updatedAt: Date(timeIntervalSince1970: 1_786_528_800))
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
