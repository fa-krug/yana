import Foundation

/// Minimal Reddit-markdown → HTML converter porting `reddit/markdown.py`.
/// Handles Reddit extensions (superscript, strikethrough, spoilers, preview images),
/// a pragmatic markdown subset (paragraphs, links, bold/italic, blockquotes, lists),
/// then auto-linkifies bare URLs and forces links to open in a new tab.
enum RedditMarkdown {
    static func toHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var t = String(text.prefix(100_000))     // DoS guard (server: 100KB)
        t = protectBackslashEscapes(t)            // hide `\`-escaped punctuation from markdown + escaping
        t = escape(t)          // escape user-generated text before emitting any HTML tags

        t = replaceGiphyEmbeds(t)
        t = replacePreviewImages(t)
        t = applyInline(t)                        // superscript / strikethrough / spoiler
        var html = blocksToHTML(t)                // paragraphs / lists / blockquotes / inline emphasis+links
        html = linkifyAndTarget(html)
        return restoreBackslashEscapes(html)      // emit `\`-escaped punctuation as literal (HTML-safe) chars
    }

    // MARK: - Backslash escapes (CommonMark)

    /// Punctuation a leading backslash escapes (the CommonMark ASCII-punctuation set).
    private static let escapablePunctuation = Array(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)
    private static let escapableIndex: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, c) in escapablePunctuation.enumerated() { m[c] = i }
        return m
    }()
    private static let placeholderBase: UInt32 = 0xE000   // private-use area, never in real text

    /// Replace `\<punct>` with a private-use placeholder so the escaped character is
    /// interpreted neither as markdown nor as an HTML metacharacter; restored at the end.
    private static func protectBackslashEscapes(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        let chars = Array(s)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, let idx = escapableIndex[chars[i + 1]],
               let scalar = Unicode.Scalar(placeholderBase + UInt32(idx)) {
                out.unicodeScalars.append(scalar)
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private static func restoreBackslashEscapes(_ s: String) -> String {
        let upper = placeholderBase + UInt32(escapablePunctuation.count)
        guard s.unicodeScalars.contains(where: { $0.value >= placeholderBase && $0.value < upper }) else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if scalar.value >= placeholderBase, scalar.value < upper {
                let ch = escapablePunctuation[Int(scalar.value - placeholderBase)]
                switch ch {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                default: out.append(ch)
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Reddit Giphy embeds

    /// Reddit encodes Giphy GIFs/Clips as `![gif](giphy|<id>[|<size>])` rather than a real
    /// image URL. Turn them into an `<img>` pointing at Giphy's media CDN so the GIF renders
    /// inline instead of leaking the raw markdown as visible text.
    private static func replaceGiphyEmbeds(_ text: String) -> String {
        regexReplace(text, #"!\[[^\]]*\]\(giphy\|([A-Za-z0-9_-]{1,100})(?:\|[^)]{0,100})?\)"#) { groups in
            "<img src=\"https://media.giphy.com/media/\(groups[1])/giphy.gif\" alt=\"Giphy\">"
        }
    }

    // MARK: - Reddit preview images

    private static func replacePreviewImages(_ text: String) -> String {
        var t = text
        // markdown link to preview image -> <img>
        t = regexReplace(t, #"\[([^\]]{0,200})\]\((https?://preview\.redd\.it/[^\s)]{1,500})\)"#) { groups in
            let alt = groups[1].isEmpty ? "Reddit preview image" : groups[1]
            return "<img src=\"\(decodeEntities(groups[2]))\" alt=\"\(alt)\">"
        }
        // bare preview image url -> <img> (not already inside a markdown link, and not the
        // src of an <img> the markdown-link pass just emitted — `(?<!")` skips attribute URLs
        // so we don't re-wrap a tag and leak its `alt="...">` as visible text)
        t = regexReplace(t, #"(?<!\]\()(?<!")https?://preview\.redd\.it/[^\s)]+"#) { groups in
            "<img src=\"\(decodeEntities(groups[0]))\" alt=\"Reddit preview image\">"
        }
        return t
    }

    // MARK: - Reddit inline extensions (applied to raw text, pre-block)

    private static func applyInline(_ text: String) -> String {
        var t = text
        t = regexReplace(t, #"\^\(([^)]+)\)"#) { "<sup>\($0[1])</sup>" }
        t = regexReplace(t, #"\^(\w+)"#) { "<sup>\($0[1])</sup>" }
        t = regexReplace(t, #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        t = regexReplace(t, #"&gt;!(.+?)!&lt;"#) {
            "<span class=\"spoiler\" style=\"background: #000; color: #000;\">\($0[1])</span>"
        }
        return t
    }

    // MARK: - Block-level markdown

    private static func blocksToHTML(_ text: String) -> String {
        // Split into blank-line-delimited blocks.
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            if lines.allSatisfy({ $0.hasPrefix("&gt; ") || $0 == "&gt;" }) {
                let inner = lines.map { line in
                    emphasisAndLinks(String(line.dropFirst(line.hasPrefix("&gt; ") ? 5 : 4)))
                }.joined(separator: "<br>")
                out.append("<blockquote><p>\(inner)</p></blockquote>")
            } else if lines.allSatisfy({ isUnorderedItem($0) }) {
                let items = lines.map { "<li>\(emphasisAndLinks(stripBullet($0)))</li>" }.joined()
                out.append("<ul>\(items)</ul>")
            } else if lines.allSatisfy({ isOrderedItem($0) }) {
                let items = lines.map { "<li>\(emphasisAndLinks(stripNumber($0)))</li>" }.joined()
                out.append("<ol>\(items)</ol>")
            } else {
                // Paragraph: single newlines become <br> (nl2br parity).
                let joined = lines.map { emphasisAndLinks($0) }.joined(separator: "<br>")
                out.append("<p>\(joined)</p>")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }
    private static func stripBullet(_ line: String) -> String { String(line.dropFirst(2)) }
    private static func isOrderedItem(_ line: String) -> Bool {
        line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }
    private static func stripNumber(_ line: String) -> String {
        regexReplace(line, #"^\d+\.\s"#) { _ in "" }
    }

    // MARK: - Inline emphasis + markdown links (within a line)

    private static func emphasisAndLinks(_ line: String) -> String {
        var s = line
        s = regexReplace(s, #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#) { g in
            "<a href=\"\(decodeEntities(g[2]))\">\(g[1])</a>"
        }
        s = regexReplace(s, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = regexReplace(s, #"\*(.+?)\*"#) { "<em>\($0[1])</em>" }
        s = regexReplace(s, #"`([^`]+)`"#) { "<code>\($0[1])</code>" }
        return s
    }

    // MARK: - Linkify bare URLs + force target/rel on every anchor

    private static func linkifyAndTarget(_ html: String) -> String {
        // Linkify bare URLs that are not already inside an href/anchor.
        var out = regexReplace(html, #"(?<!["'=>])(https?://[^\s<"]+)"#) { g in
            let raw = g[1]
            let clean = raw.replacingOccurrences(of: #"[.,;:!?)]+$"#, with: "", options: .regularExpression)
            let trailing = String(raw.dropFirst(clean.count))
            return "<a href=\"\(clean)\">\(clean)</a>\(trailing)"
        }
        // Force target/rel on every anchor, appending after existing attributes so
        // the `href` stays adjacent to the opening `<a `. Idempotent: anchors that
        // already declare target= are skipped via the negative lookahead.
        out = regexReplace(out, #"<a ((?:(?!target=)[^>])*?)>"#) { g in
            "<a \(g[1]) target=\"_blank\" rel=\"noopener\">"
        }
        return out
    }

    // MARK: - Helpers

    static func escape(_ s: String) -> String {
        // Escape a bare `&` but preserve existing HTML entities (e.g. `&#x200B;`, `&#39;`,
        // `&amp;`) so the WebView decodes them rather than showing the literal source.
        // Mirrors Python-Markdown, which leaves character references intact.
        regexReplace(s, #"&(?!(?:#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);)"#) { _ in "&amp;" }
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decodeEntities(_ s: String) -> String {
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Regex replace with a closure receiving capture groups (group 0 = whole match).
    private static func regexReplace(_ input: String, _ pattern: String,
                                     _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for match in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
