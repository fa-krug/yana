import Foundation

/// Plain transfer object for a feed in an OPML document. SwiftData-free so the codec is
/// trivially testable. `aggregatorType`/`optionsJSONBase64` are absent (nil/empty) for
/// foreign OPML produced by other readers.
struct OPMLFeed: Equatable, Sendable {
    var name: String
    var identifier: String
    var aggregatorType: String?
    var optionsJSONBase64: String
    var tags: [String]
    var dailyLimit: Int?
    var enabled: Bool?
}

enum OPMLCodec {
    // MARK: Encode

    static func encode(_ feeds: [OPMLFeed]) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<opml version=\"2.0\" xmlns:yana=\"https://fa-krug.de/yana\">")
        lines.append("  <head><title>Yana Feeds</title></head>")
        lines.append("  <body>")
        for feed in feeds {
            lines.append("    " + outline(for: feed))
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private static func outline(for feed: OPMLFeed) -> String {
        var attrs: [String] = [
            "text=\"\(escape(feed.name))\"",
            "title=\"\(escape(feed.name))\"",
            "type=\"rss\"",
            "xmlUrl=\"\(escape(feed.identifier))\"",
        ]
        if let type = feed.aggregatorType {
            attrs.append("yana:aggregatorType=\"\(escape(type))\"")
        }
        if !feed.optionsJSONBase64.isEmpty {
            attrs.append("yana:options=\"\(escape(feed.optionsJSONBase64))\"")
        }
        if !feed.tags.isEmpty {
            attrs.append("yana:tags=\"\(escape(feed.tags.joined(separator: ",")))\"")
        }
        if let limit = feed.dailyLimit {
            attrs.append("yana:dailyLimit=\"\(limit)\"")
        }
        if let enabled = feed.enabled {
            attrs.append("yana:enabled=\"\(enabled)\"")
        }
        return "<outline " + attrs.joined(separator: " ") + " />"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
