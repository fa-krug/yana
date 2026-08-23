import Foundation

/// Flattens a `[Block]` article body to its visible plain text.
///
/// This used to be one half of a two-way parser; the other half turned sanitized article HTML into
/// `[Block]`. Article bodies now arrive already parsed as `[Block]` JSON from the server (see
/// `WireDocument`/`SyncWriter.applyContent`), so that half only survived for the one-time
/// legacy-HTML migration sweep and the DEBUG fixtures. Both are gone: the sweep has served its
/// purpose and the fixtures author `[Block]` values directly, which also took the SwiftSoup
/// dependency out of the app. **There is no HTML anywhere in the client any more** — if you find
/// yourself reaching for an HTML parser, the content should be coming from the server as blocks.
///
/// What remains is load-bearing for every article regardless of origin: `Article.blocks`'s setter
/// calls it to derive the search and read-aloud surface stored on `Article.plainText`.
enum BlockParser {
    /// Flatten blocks to visible plain text — the search and speech surface stored on
    /// `Article.plainText`. Sections are separated by blank lines.
    static func plainText(_ blocks: [Block]) -> String {
        var parts: [String] = []
        func runsText(_ runs: [InlineRun]) -> String { runs.map(\.text).joined() }
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case .paragraph(let runs): parts.append(runsText(runs))
                case .heading(_, let runs): parts.append(runsText(runs))
                case .list(_, let items): for item in items { walk(item) }
                case .blockquote(let inner): walk(inner)
                // The summary is part of the visible body, so it belongs in both surfaces this
                // feeds: searching for a phrase that appears in a summary should find the article,
                // and read-aloud reads the summary before the article just as the reader shows it
                // first. `ReaderActions.summarize` strips it back out of its own input
                // (`Block.removingSummaries`) so the model never summarizes a summary.
                case .summary(let inner): walk(inner)
                case .image(_, let caption):
                    let c = runsText(caption)
                    if !c.isEmpty { parts.append(c) }
                case .embed(let embed): if let t = embed.title { parts.append(t) }
                case .codeBlock(let text, _): parts.append(text)
                case .divider: break
                }
            }
        }
        walk(blocks)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
