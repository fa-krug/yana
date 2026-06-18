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

    // Fixed-format dates (RSS pubDate, date-only) — cached, built once instead of
    // per call. Configured once at init then used read-only (`date(from:)`), which
    // is thread-safe. Order matters: most specific (with seconds) first.
    private static let fixedFormatters: [DateFormatter] = {
        [
            "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z", "EEE, dd MMM yyyy HH:mm zzz",   // seconds omitted
            "yyyy-MM-dd'T'HH:mm:ssZ",                                   // ISO without 'Z' literal
            "yyyy-MM-dd HH:mm:ss",                                      // space-separated, no zone
            "yyyy-MM-dd",                                               // date only
        ].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
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
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let d = isoPlain.date(from: trimmed) { return d }
        if let d = isoFractional.date(from: trimmed) { return d }
        for f in fixedFormatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [FeedEntry] = []
    private var current: FeedEntry?
    private var text = ""
    private var inItem = false
    /// Atom <updated> date, used only as a fallback when no original publication
    /// date (<published>/pubDate/dc:date) is present. Reset per item.
    private var updatedFallback: Date?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes attrs: [String: String]) {
        text = ""
        let lower = name.lowercased()
        if lower == "item" || lower == "entry" {
            inItem = true
            current = FeedEntry()
            updatedFallback = nil
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

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName qn: String?) {
        let lower = name.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard inItem, current != nil else { return }
        if lower == "item" || lower == "entry" {
            if current?.published == nil { current?.published = updatedFallback }
            if let c = current { entries.append(c) }
            current = nil
            inItem = false
            return
        }
        assignField(lower, trimmed: trimmed)
    }

    /// Assign a parsed element's trimmed text onto the current entry's matching field.
    private func assignField(_ lower: String, trimmed: String) {
        if assignDirectField(lower, trimmed: trimmed) { return }
        assignConditionalField(lower, trimmed: trimmed)
    }

    /// Fields that always overwrite. Returns `true` when `lower` matched a direct field.
    private func assignDirectField(_ lower: String, trimmed: String) -> Bool {
        switch lower {
        case "title": current?.title = trimmed
        case "description": current?.entryDescription = trimmed
        case "summary": current?.summary = trimmed
        case "content:encoded", "content": current?.content = trimmed
        case "itunes:duration": current?.itunesDuration = trimmed
        default: return false
        }
        return true
    }

    /// Fields that only set when not already populated (first-wins).
    private func assignConditionalField(_ lower: String, trimmed: String) {
        switch lower {
        case "link" where !trimmed.isEmpty:
            if current?.link.isEmpty ?? true { current?.link = trimmed }
        case "author", "dc:creator", "name":
            if current?.author.isEmpty ?? true { current?.author = trimmed }
        case "pubdate", "published", "dc:date":
            // Original publication date — authoritative for timeline ordering.
            if current?.published == nil { current?.published = FeedParser.parseDate(trimmed) }
        case "updated":
            // Last-modified date — only a fallback (resolved at item end).
            if updatedFallback == nil { updatedFallback = FeedParser.parseDate(trimmed) }
        default: break
        }
    }
}
