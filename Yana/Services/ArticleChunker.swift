import Foundation
import SwiftSoup

/// Splits article HTML into chunks whose estimated token count fits a budget, breaking on
/// top-level block boundaries so HTML elements are never cut mid-tag. A single block larger
/// than the budget is hard-split by characters as a fallback.
enum ArticleChunker {
    static func chunk(html: String, budgetTokens: Int, tokenCount: (String) -> Int) -> [String] {
        let budget = max(1, budgetTokens)

        // Top-level block elements; fall back to the whole string if parsing yields nothing.
        let blocks: [String]
        if let body = try? SwiftSoup.parse(html).body(),
           let children = try? body.children().array(),
           !children.isEmpty {
            blocks = children.compactMap { try? $0.outerHtml() }
        } else {
            blocks = [html]
        }

        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }

        for block in blocks {
            if tokenCount(block) > budget {
                // Block alone exceeds budget: flush, then hard-split this block by characters.
                flush()
                chunks.append(contentsOf: hardSplit(block, budgetTokens: budget))
                continue
            }
            let candidate = current.isEmpty ? block : current + "\n" + block
            if tokenCount(candidate) > budget {
                flush()
                current = block
            } else {
                current = candidate
            }
        }
        flush()
        return chunks.isEmpty ? [html] : chunks
    }

    /// Character-based fallback split for an oversized single block. Conservative char bound
    /// (budget * 3) keeps each piece within the token budget under the ~3.5 chars/token estimate.
    private static func hardSplit(_ s: String, budgetTokens: Int) -> [String] {
        let charBudget = max(1, budgetTokens * 3)
        var pieces: [String] = []
        var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: charBudget, limitedBy: s.endIndex) ?? s.endIndex
            pieces.append(String(s[index..<end]))
            index = end
        }
        return pieces
    }
}
