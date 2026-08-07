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
