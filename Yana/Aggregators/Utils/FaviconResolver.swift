import Foundation
import SwiftSoup

/// Finds a site's best icon by parsing its HTML `<link rel>` tags (apple-touch-icon preferred,
/// then largest declared size), with a `/favicon.ico` network fallback. Only ever contacts the
/// site's own domain — no third-party favicon services.
enum FaviconResolver {
    /// Pure selection from parsed HTML. Returns the absolute URL of the best icon link, or nil
    /// when the page declares no icon link (caller then tries `/favicon.ico`).
    static func bestIconURL(fromHTML html: String, baseURL: URL) -> String? {
        guard let doc = try? SwiftSoup.parse(html, baseURL.absoluteString),
              let links = try? doc.select("link[rel]") else { return nil }

        struct Candidate { let href: String; let isAppleTouch: Bool; let area: Int }
        var candidates: [Candidate] = []
        for link in links.array() {
            let rel = ((try? link.attr("rel")) ?? "").lowercased()
            let tokens = rel.split(whereSeparator: { $0 == " " }).map(String.init)
            let isAppleTouch = rel.contains("apple-touch-icon")
            let isIcon = isAppleTouch || tokens.contains("icon")
            guard isIcon else { continue }
            let href = (try? link.attr("href")) ?? ""
            guard !href.isEmpty else { continue }
            let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL.absoluteString ?? href
            candidates.append(Candidate(href: resolved, isAppleTouch: isAppleTouch,
                                        area: sizeArea((try? link.attr("sizes")) ?? "")))
        }
        guard !candidates.isEmpty else { return nil }
        // apple-touch-icon wins; otherwise the largest declared size.
        let best = candidates.max { a, b in
            if a.isAppleTouch != b.isAppleTouch { return !a.isAppleTouch && b.isAppleTouch }
            return a.area < b.area
        }
        return best?.href
    }

    /// Parses the first WxH from a `sizes` attribute (e.g. "180x180" -> 32400). 0 when absent.
    private static func sizeArea(_ sizes: String) -> Int {
        let parts = sizes.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return 0 }
        return w * h
    }
}
