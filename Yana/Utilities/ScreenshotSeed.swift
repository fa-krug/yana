#if DEBUG
import Foundation
import SwiftData

/// Curated, network-free library for App Store screenshots. Gated by the
/// `-UITEST_SCREENSHOTS` launch argument so it never runs on a normal launch or on the
/// `YANA_SEED_ARTICLES` performance path. Idempotent: bails if any Feed already exists.
enum ScreenshotSeed {
    static let launchArgument = "-UITEST_SCREENSHOTS"

    @MainActor
    static func seedIfRequested(into context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        await seed(into: context)
    }

    /// One curated feed per aggregator flavor, each contributing a few articles.
    private struct FeedSpec {
        let name: String
        let type: AggregatorType
        let tagName: String
        let tagColorHex: String
        let articles: [(title: String, author: String, summary: String)]
    }

    private static let specs: [FeedSpec] = [
        FeedSpec(name: "Heise Online", type: .feedContent, tagName: "Tech", tagColorHex: "#2E77D0", articles: [
            ("Apple ships on-device RSS: privacy without a server", "Jantje Cordes",
             "A new wave of local-first readers keeps your feeds entirely on the phone — no account, no cloud sync, no tracking."),
            ("Swift 6 concurrency lands across the ecosystem", "Malte Kuhr",
             "Strict concurrency checking is now the default, and libraries are racing to adopt @MainActor and Sendable."),
            ("The quiet return of the personal feed reader", "Hanna Vogt",
             "RSS never died. Here's why a focused, on-device reader beats an algorithmic timeline."),
        ]),
        FeedSpec(name: "Tagesschau", type: .feedContent, tagName: "News", tagColorHex: "#D0392E", articles: [
            ("Morning briefing: everything you missed overnight", "Redaktion",
             "The stories shaping the day, gathered while you slept."),
            ("Explainer: how aggregation keeps you in control", "Redaktion",
             "You choose the sources. The app just fetches and organizes."),
            ("Weather roundup: a calm week ahead nationwide", "Redaktion",
             "Sunshine returns after a stormy weekend across most regions."),
        ]),
        FeedSpec(name: "Marques on YouTube", type: .youtube, tagName: "Video", tagColorHex: "#7A2ED0", articles: [
            ("The best phone for reading in 2026", "MKBHD",
             "Screen, battery, and the underrated joy of a great reading app."),
            ("I replaced my news apps with one RSS reader", "MKBHD",
             "A week living entirely inside a self-contained feed aggregator."),
        ]),
        FeedSpec(name: "r/apple", type: .reddit, tagName: "Community", tagColorHex: "#D07A2E", articles: [
            ("What feed reader are you using in 2026?", "u/feedfan",
             "The community weighs in on native, privacy-first readers."),
            ("PSA: OPML import makes switching painless", "u/switcher",
             "Bring every subscription over in one file."),
        ]),
        FeedSpec(name: "Accidental Tech Podcast", type: .podcast, tagName: "Audio", tagColorHex: "#2EB8D0", articles: [
            ("Episode 612: The local-first renaissance", "ATP",
             "Why on-device processing is the story of the year."),
            ("Episode 611: Feeds, tags, and taste", "ATP",
             "Organizing information without an algorithm deciding for you."),
        ]),
    ]

    @MainActor
    static func seed(into context: ModelContext) async {
        // Idempotency guard.
        if let existing = try? context.fetch(FetchDescriptor<Feed>()), !existing.isEmpty { return }

        var globalIndex = 0
        var articleIdentifiers: [String] = []

        for spec in specs {
            let feed = Feed(name: spec.name, aggregatorType: spec.type,
                            identifier: "screenshot://\(spec.name)")
            context.insert(feed)

            let tag = Tag(name: spec.tagName, colorHex: spec.tagColorHex)
            context.insert(tag)
            feed.tags = [tag]

            for item in spec.articles {
                let identifier = "screenshot://article/\(globalIndex)"
                let article = Article(
                    title: item.title,
                    identifier: identifier,
                    url: "https://example.com/screenshot/\(globalIndex)",
                    date: .now,
                    author: item.author,
                    summary: item.summary
                )
                let imageRef = await leadImageRef(for: globalIndex)
                article.blocks = BlockParser.blocks(fromHTML: body(imageRef: imageRef, item: item))
                article.createdAt = Date(timeIntervalSinceNow: -Double(globalIndex) * 5400)
                article.feed = feed
                article.tags = [tag]
                context.insert(article)
                articleIdentifiers.append(identifier)
                globalIndex += 1
            }
        }

        do {
            try context.save()
            // Park the anchor on the first article of the third feed (a visually rich one)
            // so the reader opens on a good hero shot.
            let anchor = articleIdentifiers.indices.contains(6)
                ? articleIdentifiers[6] : articleIdentifiers.first
            AppSettings().timelineAnchorIdentifier = anchor
            NSLog("ScreenshotSeed: inserted \(articleIdentifiers.count) articles, anchor=\(anchor ?? "nil")")
        } catch {
            NSLog("ScreenshotSeed: save failed: \(error)")
        }
    }

    private static func leadImageRef(for index: Int) async -> String {
        let data = ScreenshotImageFactory.jpeg(index: index)
        let hash = await ImageStore.shared.storeData(data, ext: "jpg")
        return "\(ReaderWeb.imageScheme)://\(hash)"
    }

    private static func body(imageRef: String, item: (title: String, author: String, summary: String)) -> String {
        // Lead image first (becomes the reader lead image + timeline thumbnail), then the
        // summary as an emphasized lead paragraph, then a couple of body paragraphs.
        """
        <img src="\(imageRef)" alt="">
        <p><strong>\(item.summary)</strong></p>
        <p>\(String(repeating: "This is curated screenshot copy that reads like a real article without depending on any network fetch. ", count: 3))</p>
        <p>\(String(repeating: "Feeds are aggregated on-device, organized with tags, and read in a clean native reader. ", count: 3))</p>
        """
    }
}
#endif
