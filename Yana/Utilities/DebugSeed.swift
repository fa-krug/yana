#if DEBUG
import Foundation
import SwiftData

/// Debug-only fixture seeding for startup measurement. Triggered by the `YANA_SEED_ARTICLES`
/// environment variable (set to a count, e.g. `100`). Inserts a feed + that many articles with
/// realistic block bodies, spreads their `date` across recent days, and parks a timeline
/// anchor on a middle article so the reader exercises its render path on the next launch.
///
/// Intended workflow: launch once with the env var set to seed, then launch normally to measure.
enum DebugSeed {
    @MainActor
    static func seedIfRequested(into context: ModelContext) {
        guard let raw = ProcessInfo.processInfo.environment["YANA_SEED_ARTICLES"],
              let count = Int(raw), count > 0 else { return }

        let feed = Feed(name: "Seed Feed", identifier: "seed://feed")
        context.insert(feed)

        var anchorIdentifier: String?
        for i in 0..<count {
            let identifier = "seed://article/\(i)"
            // Spread across the last `count` hours so the timeline/anchor logic is realistic.
            let seededDate = Date(timeIntervalSinceNow: -Double(count - i) * 3600)
            let article = Article(
                title: "Seeded Article \(i): The Quick Brown Fox",
                identifier: identifier,
                url: "https://example.com/seed/\(i)",
                date: seededDate,
                author: "Author \(i % 7)"
            )
            article.blocks = body(i)
            article.createdAt = seededDate
            article.feed = feed
            context.insert(article)
            if i == count / 2 { anchorIdentifier = identifier }
        }

        do {
            try context.save()
            AppSettings().timelineAnchorIdentifier = anchorIdentifier
            NSLog("DebugSeed: inserted \(count) articles, anchor=\(anchorIdentifier ?? "nil")")
        } catch {
            NSLog("DebugSeed: save failed: \(error)")
        }
    }

    /// Authored as `[Block]` directly — the same shape the server delivers. No image block: a
    /// network round-trip would pollute the cold-start paint measurement with latency the app
    /// does not control.
    private static func body(_ i: Int) -> [Block] {
        var blocks: [Block] = [.heading(level: 1, runs: [InlineRun(text: "Seeded Article \(i)")])]
        for p in 0..<8 {
            let text = "Paragraph \(p) of seeded article \(i). " +
                String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 6)
            blocks.append(.paragraph([InlineRun(text: text)]))
        }
        return blocks
    }
}
#endif
