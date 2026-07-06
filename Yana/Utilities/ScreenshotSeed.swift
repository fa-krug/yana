#if DEBUG
import Foundation
import SwiftData

/// Curated, network-free library for App Store screenshots. Gated by the
/// `-UITEST_SCREENSHOTS` launch argument so it never runs on a normal launch or on the
/// `YANA_SEED_ARTICLES` performance path. Idempotent: bails if any Feed already exists.
///
/// Authors a small library of fully ORIGINAL feeds/articles in-code (no third-party content,
/// no network) and generates every image in-process: `ScreenshotLogoFactory` for feed logos and
/// `ScreenshotImageFactory` for article lead images, both stored content-addressed via
/// `ImageStore` so the resulting `yana-img://<hash>` refs resolve like any real import.
enum ScreenshotSeed {
    static let launchArgument = "-UITEST_SCREENSHOTS"

    /// One authored article: title/author/summary plus the body paragraphs (rendered after the
    /// generated lead image). Only the hero's body is ever visible in a screenshot; every other
    /// article reuses `genericBodyParagraph` to keep its blocks non-empty and real.
    private struct ArticleSpec {
        let title: String
        let author: String
        let summary: String
        let bodyParagraphs: [String]
    }

    /// One authored feed: name, tag, monogram/color for the generated logo, and its articles.
    private struct FeedSpec {
        let name: String
        let identifier: String
        let tagName: String
        let tagColorHex: String
        let monogram: String
        let url: String
        let articles: [ArticleSpec]
    }

    /// Reused for every non-hero article. Never shown in a screenshot, but keeps every body
    /// genuinely non-empty rather than a placeholder.
    private static let genericBodyParagraph =
        "It's the kind of story that reads well on a phone: a clear headline, a few tight " +
        "paragraphs, and nothing between you and the words. Aggregated on-device, organized " +
        "with tags, and kept entirely on your phone."

    private static let feedSpecs: [FeedSpec] = [
        FeedSpec(
            name: "Byte Report", identifier: "https://example.com/byte-report",
            tagName: "Tech", tagColorHex: "#2E77D0", monogram: "BR",
            url: "https://example.com/byte-report",
            articles: [
                ArticleSpec(
                    title: "The new e-ink tablets are getting seriously fast",
                    author: "Dana Whitfield",
                    summary: "This year's color e-ink panels finally refresh quickly enough to " +
                        "make note-taking feel instant — and the battery still lasts for weeks.",
                    bodyParagraphs: [
                        "For years the trade-off with e-ink was simple: gorgeous, easy-on-the-eyes " +
                            "text in exchange for sluggish page turns and washed-out color. That " +
                            "bargain is quietly falling apart.",
                        "The latest panels refresh fast enough that scrolling a long article no " +
                            "longer feels like a negotiation, and handwriting lands under the " +
                            "stylus with almost no lag. Color is still muted next to an OLED, but " +
                            "for reading and margin notes it is finally good enough to forget about.",
                        "What hasn't changed is the part that mattered all along — days, sometimes " +
                            "weeks, between charges, and a matte surface you can read in direct " +
                            "sun. The result is a device that gets out of the way and just lets you read."
                    ]
                ),
                ArticleSpec(
                    title: "A field guide to squeezing more battery from your laptop",
                    author: "Marcus Bell",
                    summary: "Small habits around display, background sync, and a couple of " +
                        "firmware toggles add up to real hours.",
                    bodyParagraphs: [genericBodyParagraph]
                ),
                ArticleSpec(
                    title: "Mechanical keyboards are quietly having another moment",
                    author: "Dana Whitfield",
                    summary: "Low-profile switches and wireless boards are pulling a niche hobby " +
                        "back into the mainstream.",
                    bodyParagraphs: [genericBodyParagraph]
                )
            ]
        ),
        FeedSpec(
            name: "The Daily Brief", identifier: "https://example.com/daily-brief",
            tagName: "News", tagColorHex: "#D0392E", monogram: "DB",
            url: "https://example.com/daily-brief",
            articles: [
                ArticleSpec(
                    title: "Morning briefing: the three stories shaping today",
                    author: "Newsroom",
                    summary: "Everything worth knowing before your first coffee, gathered overnight.",
                    bodyParagraphs: [genericBodyParagraph]
                ),
                ArticleSpec(
                    title: "New spectrum rules could reshape rural coverage",
                    author: "Newsroom",
                    summary: "Regulators opened a band that carriers have wanted for a decade.",
                    bodyParagraphs: [genericBodyParagraph]
                )
            ]
        ),
        FeedSpec(
            name: "Overtake", identifier: "https://example.com/overtake",
            tagName: "Video", tagColorHex: "#7A2ED0", monogram: "OV",
            url: "https://example.com/overtake",
            articles: [
                ArticleSpec(
                    title: "I tested every budget e-reader so you don't have to",
                    author: "Priya Nair",
                    summary: "Six readers, one month, and a clear winner under $150.",
                    bodyParagraphs: [genericBodyParagraph]
                ),
                ArticleSpec(
                    title: "The truth about fast charging and battery health",
                    author: "Priya Nair",
                    summary: "We ran the cycles so you can stop worrying about charging overnight.",
                    bodyParagraphs: [genericBodyParagraph]
                )
            ]
        ),
        FeedSpec(
            name: "The Commons", identifier: "https://example.com/the-commons",
            tagName: "Community", tagColorHex: "#D07A2E", monogram: "TC",
            url: "https://example.com/the-commons",
            articles: [
                ArticleSpec(
                    title: "What's your no-frills RSS setup in 2026?",
                    author: "quietreader",
                    summary: "The thread where everyone shares the boring, reliable tools they actually use.",
                    bodyParagraphs: [genericBodyParagraph]
                ),
                ArticleSpec(
                    title: "OPML import makes switching readers painless",
                    author: "switcher",
                    summary: "Move every subscription over in a single file.",
                    bodyParagraphs: [genericBodyParagraph]
                )
            ]
        ),
        FeedSpec(
            name: "Offline Hours", identifier: "https://example.com/offline-hours",
            tagName: "Audio", tagColorHex: "#2EB8D0", monogram: "OH",
            url: "https://example.com/offline-hours",
            articles: [
                ArticleSpec(
                    title: "Episode 142: The local-first renaissance",
                    author: "Offline Hours",
                    summary: "Why keeping your data on your own device is the story of the year.",
                    bodyParagraphs: [genericBodyParagraph]
                ),
                ArticleSpec(
                    title: "Episode 141: Taste, tags, and timelines",
                    author: "Offline Hours",
                    summary: "Organizing information without an algorithm deciding for you.",
                    bodyParagraphs: [genericBodyParagraph]
                )
            ]
        )
    ]

    @MainActor
    static func seedIfRequested(into context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        await seed(into: context)
    }

    @MainActor
    static func seed(into context: ModelContext) async {
        // Idempotency guard.
        if let existing = try? context.fetch(FetchDescriptor<Feed>()), !existing.isEmpty { return }

        var globalIndex = 0
        var articleIdentifiers: [String] = []
        var anchorIdentifier: String?
        var tagsByName: [String: Tag] = [:]

        for (feedIndex, spec) in feedSpecs.enumerated() {
            let feed = Feed(name: spec.name, aggregatorType: .feedContent, identifier: spec.identifier)

            let logoData = ScreenshotLogoFactory.png(monogram: spec.monogram, colorHex: spec.tagColorHex)
            feed.logoHash = await ImageStore.shared.storeData(logoData, ext: "png")
            context.insert(feed)

            let tag: Tag
            if let existingTag = tagsByName[spec.tagName] {
                tag = existingTag
            } else {
                tag = Tag(name: spec.tagName, colorHex: spec.tagColorHex)
                context.insert(tag)
                tagsByName[spec.tagName] = tag
            }
            feed.tags = [tag]

            for (articleIndex, articleSpec) in spec.articles.enumerated() {
                let identifier = "screenshot://\(feedIndex)/\(articleIndex)"

                let leadData = ScreenshotImageFactory.jpeg(index: globalIndex)
                let leadHash = await ImageStore.shared.storeData(leadData, ext: "jpg")

                var html = "<img src=\"yana-img://\(leadHash)\" alt=\"\">"
                for paragraph in articleSpec.bodyParagraphs {
                    html += "<p>\(paragraph)</p>"
                }

                let when = Date(timeIntervalSinceNow: -Double(globalIndex) * 5400)
                let article = Article(
                    title: articleSpec.title,
                    identifier: identifier,
                    url: spec.url,
                    date: when,
                    author: articleSpec.author,
                    summary: articleSpec.summary
                )
                article.blocks = BlockParser.blocks(fromHTML: html)
                article.createdAt = when
                article.feed = feed
                article.tags = [tag]
                context.insert(article)
                articleIdentifiers.append(identifier)

                if feedIndex == 0 && articleIndex == 0 {
                    anchorIdentifier = identifier
                }
                globalIndex += 1
            }
        }

        do {
            try context.save()
            let anchor = anchorIdentifier ?? articleIdentifiers.first
            AppSettings().timelineAnchorIdentifier = anchor
            NSLog("ScreenshotSeed: inserted \(articleIdentifiers.count) articles, anchor=\(anchor ?? "nil")")
        } catch {
            NSLog("ScreenshotSeed: save failed: \(error)")
        }
    }
}
#endif
