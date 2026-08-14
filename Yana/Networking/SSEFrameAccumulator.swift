import Foundation

/// One complete Server-Sent Events frame: an optional `event:` name and the (possibly
/// multi-line, newline-joined) `data:` payload. `yana-server`'s `/api/v1/jobs/events` sends
/// `event: job`/`event: run` frames plus bare `: ping` comment frames with no data at all.
struct SSEFrame: Equatable, Sendable {
    let event: String?
    let data: String
}

/// Feed this one already-newline-split line at a time. Per the SSE spec: a blank line
/// terminates and emits the current frame; a line starting with `:` is a comment (used by the
/// server purely as a keep-alive ping) and is ignored; `field: value` lines set that field, with
/// exactly one leading space after the colon stripped if present. A blank line with no `data:`
/// line seen (e.g. only a ping comment before it) emits no frame.
///
/// Deliberately NOT fed from `URLSession.AsyncBytes.lines`: SSE's blank line is the frame
/// terminator this type depends on, but `AsyncLineSequence` silently drops empty lines rather
/// than yielding them (confirmed empirically -- a stream of "a\n\nb\n" yields only `["a", "b"]`,
/// never an empty string in between), so frames would never terminate. `JobEventsClient` instead
/// hand-splits on `UInt8(ascii: "\n")`, which does preserve empty lines.
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
