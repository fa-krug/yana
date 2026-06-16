import Foundation

struct FeedEnclosure: Sendable { var url: String; var type: String? }

struct FeedEntry: Sendable {
    var title = ""
    var link = ""
    var content: String?
    var summary: String?
    var entryDescription: String?
    var published: Date?
    var author = ""
    var enclosures: [FeedEnclosure] = []
    var itunesDuration: String?
    var itunesImage: String?
    var mediaThumbnails: [String] = []
}

struct ParsedFeed: Sendable { var entries: [FeedEntry] }

/// Minimal RSS 2.0 / RDF / Atom parser (replaces feedparser). Tolerant of namespaces.
enum FeedParser {
    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = FeedXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false   // keep prefixed names like content:encoded, itunes:duration
        guard parser.parse() else {
            throw AggregatorError.parse(parser.parserError?.localizedDescription ?? "invalid feed XML")
        }
        return ParsedFeed(entries: delegate.entries)
    }

    // RFC 822 (RSS pubDate) — cached, built once instead of per call.
    // Configured once at init then used read-only (`date(from:)`), which is thread-safe.
    nonisolated(unsafe) private static let rfc822Formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    // ISO 8601 (Atom updated/published) — cached, used read-only.
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        for f in rfc822Formatters {
            if let d = f.date(from: s) { return d }
        }
        if let d = isoPlain.date(from: s) { return d }
        return isoFractional.date(from: s)
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [FeedEntry] = []
    private var current: FeedEntry?
    private var text = ""
    private var inItem = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qn: String?, attributes attrs: [String: String]) {
        text = ""
        let lower = name.lowercased()
        if lower == "item" || lower == "entry" {
            inItem = true
            current = FeedEntry()
        } else if inItem, lower == "link", let href = attrs["href"], !href.isEmpty {
            let rel = attrs["rel"] ?? "alternate"     // Atom: absent rel means "alternate"
            if rel == "alternate" { current?.link = href }   // ignore self/enclosure/etc.
        } else if inItem, lower == "enclosure", let url = attrs["url"] {
            current?.enclosures.append(FeedEnclosure(url: url, type: attrs["type"]))
        } else if inItem, lower == "itunes:image", let href = attrs["href"] {
            current?.itunesImage = href
        } else if inItem, lower == "media:thumbnail", let url = attrs["url"] {
            current?.mediaThumbnails.append(url)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qn: String?) {
        let lower = name.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard inItem, current != nil else { return }
        switch lower {
        case "item", "entry":
            if let c = current { entries.append(c) }
            current = nil; inItem = false
        case "title": current?.title = trimmed
        case "link" where !trimmed.isEmpty: if current?.link.isEmpty ?? true { current?.link = trimmed }
        case "author", "dc:creator", "name": if current?.author.isEmpty ?? true { current?.author = trimmed }
        case "description": current?.entryDescription = trimmed
        case "summary": current?.summary = trimmed
        case "content:encoded", "content": current?.content = trimmed
        case "pubdate", "published", "updated", "dc:date": if current?.published == nil { current?.published = FeedParser.parseDate(trimmed) }
        case "itunes:duration": current?.itunesDuration = trimmed
        default: break
        }
    }
}
