#if DEBUG
import Foundation
import SwiftData

/// Debug-only fixture seeding for startup measurement. Triggered by the `YANA_SEED_ARTICLES`
/// environment variable (set to a count, e.g. `100`). Inserts a feed + that many articles with
/// realistic HTML bodies, spreads their `createdAt` across recent days, and parks a timeline
/// anchor on a middle article so `ReaderWarmup` exercises its render path on the next launch.
///
/// Intended workflow: launch once with the env var set to seed, then launch normally to measure.
enum DebugSeed {
    @MainActor
    static func seedIfRequested(into context: ModelContext) {
        guard let raw = ProcessInfo.processInfo.environment["YANA_SEED_ARTICLES"],
              let count = Int(raw), count > 0 else { return }

        let feed = Feed(name: "Seed Feed", aggregatorType: .feedContent, identifier: "seed://feed")
        context.insert(feed)

        var anchorIdentifier: String?
        for i in 0..<count {
            let identifier = "seed://article/\(i)"
            let article = Article(
                title: "Seeded Article \(i): The Quick Brown Fox",
                identifier: identifier,
                url: "https://example.com/seed/\(i)",
                rawContent: body(i),
                content: body(i),
                date: .now,
                author: "Author \(i % 7)"
            )
            // Spread across the last `count` hours so the timeline/anchor logic is realistic.
            article.createdAt = Date(timeIntervalSinceNow: -Double(count - i) * 3600)
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

    private static func body(_ i: Int) -> String {
        let paragraphs = (0..<8).map { p in
            "<p>Paragraph \(p) of seeded article \(i). " +
            String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 6) +
            "</p>"
        }.joined()
        // No external <img> — a network round-trip would gate WKWebView's didFinish and pollute
        // the cold-start paint measurement with latency the app does not control.
        return "<h1>Seeded Article \(i)</h1>" + paragraphs
    }
}
#endif
