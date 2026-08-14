import Foundation

/// Splits article text into chunks whose estimated token count fits a budget, breaking on paragraph
/// boundaries so a chunk never starts mid-sentence. A single paragraph larger than the budget is
/// hard-split by characters as a fallback.
///
/// This used to split *HTML* on top-level element boundaries, via SwiftSoup. That was a leftover
/// from when article bodies were HTML: its only caller passes `Article.plainText`, and parsing
/// plain text as HTML yields a body with no element children, so the splitter took its
/// "parsing yielded nothing" fallback and returned the entire article as ONE chunk. The map-reduce
/// in `AppleIntelligenceChunkedSummarizer` was therefore never exercised, and any article longer
/// than the ~4096-token on-device context window was fed to the model whole. Splitting on blank
/// lines matches what `BlockParser.plainText` actually emits (sections joined by "\n\n").
enum ArticleChunker {
    static func chunk(text: String, budgetTokens: Int, tokenCount: (String) -> Int) -> [String] {
        let budget = max(1, budgetTokens)

        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [text] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }

        for paragraph in paragraphs {
            if tokenCount(paragraph) > budget {
                // Paragraph alone exceeds budget: flush, then hard-split it by characters.
                flush()
                chunks.append(contentsOf: hardSplit(paragraph, budgetTokens: budget))
                continue
            }
            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if tokenCount(candidate) > budget {
                flush()
                current = paragraph
            } else {
                current = candidate
            }
        }
        flush()
        return chunks.isEmpty ? [text] : chunks
    }

    /// Character-based fallback split for an oversized single paragraph. Conservative char bound
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
