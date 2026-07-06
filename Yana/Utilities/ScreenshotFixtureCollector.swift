#if DEBUG
import Foundation
import SwiftData

/// Collects a frozen `ScreenshotFixture` from REAL, LIVE feeds by running the app's actual
/// aggregation pipeline once (`AggregationService.forceReload(feed:)`) against a small curated
/// set of real-world RSS/Atom sources. The result — article metadata, native `[Block]` bodies,
/// and referenced images — is written to `Documents/ScreenshotFixture/` so `ScreenshotSeed` can
/// replay it offline for App Store screenshots without ever touching the network again.
///
/// Runs against a throwaway in-memory `ModelContainer` — the app's real SwiftData store is never
/// touched. Gated by the `-COLLECT_SCREENSHOT_FIXTURE` launch argument so it never runs otherwise.
enum ScreenshotFixtureCollector {
    static let launchArgument = "-COLLECT_SCREENSHOT_FIXTURE"

    /// One real-world source per curated tag. All `.feedContent` (RSS/Atom) — including the
    /// YouTube channel and subreddit, both of which publish standard Atom/RSS feeds — so no API
    /// keys are required to collect them.
    private struct FeedSpec {
        let name: String
        let tagName: String
        let tagColorHex: String
        let url: String
    }

    private static let specs: [FeedSpec] = [
        FeedSpec(name: "The Verge", tagName: "Tech", tagColorHex: "#2E77D0",
                 url: "https://www.theverge.com/rss/index.xml"),
        FeedSpec(name: "Ars Technica", tagName: "Tech", tagColorHex: "#2E77D0",
                 url: "https://feeds.arstechnica.com/arstechnica/index"),
        FeedSpec(name: "Marques Brownlee", tagName: "Video", tagColorHex: "#7A2ED0",
                 url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ"),
        FeedSpec(name: "r/apple", tagName: "Community", tagColorHex: "#D07A2E",
                 url: "https://www.reddit.com/r/apple/.rss"),
        FeedSpec(name: "Accidental Tech Podcast", tagName: "Audio", tagColorHex: "#2EB8D0",
                 url: "https://atp.fm/rss"),
    ]

    /// Up to this many articles are kept per feed in the exported fixture.
    private static let maxArticlesPerFeed = 3
    /// Fallback cap when a feed has articles but none carry a lead image.
    private static let maxArticlesPerFeedNoImage = 2

    @MainActor
    static func collectIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        await collect()
    }

    @MainActor
    static func collect() async {
        NSLog("ScreenshotFixtureCollector: starting live collection run")

        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Feed.self, Tag.self, Article.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            NSLog("ScreenshotFixtureCollector: failed to create in-memory container: \(error)")
            return
        }
        let context = ModelContext(container)
        Tag.ensureBuiltIns(in: context)

        var fixtureFeeds: [ScreenshotFixture.Feed] = []
        var allImageHashes = Set<String>()

        for spec in specs {
            let feed = Feed(name: spec.name, aggregatorType: .feedContent, identifier: spec.url)
            let tag = Tag(name: spec.tagName, colorHex: spec.tagColorHex)
            feed.tags = [tag]
            context.insert(tag)
            context.insert(feed)
            try? context.save()

            let service = AggregationService(context: context)
            let inserted = await service.forceReload(feed: feed)
            NSLog(
                "ScreenshotFixtureCollector: feed \"\(spec.name)\" inserted=\(inserted) "
                    + "logoHash=\(feed.logoHash ?? "nil")"
            )

            if inserted == 0 && feed.articles.isEmpty {
                NSLog("ScreenshotFixtureCollector: WARNING feed \"\(spec.name)\" yielded 0 articles, skipping")
                continue
            }

            let sorted = feed.articles.sorted { $0.date > $1.date }
            let withImage = sorted.filter { article in
                if case .image = article.blocks.first { return true }
                return false
            }

            let selected: [Article]
            if !withImage.isEmpty {
                selected = Array(withImage.prefix(maxArticlesPerFeed))
            } else {
                selected = Array(sorted.prefix(maxArticlesPerFeedNoImage))
            }

            guard !selected.isEmpty else {
                NSLog("ScreenshotFixtureCollector: WARNING feed \"\(spec.name)\" has no usable articles, skipping")
                continue
            }

            var fixtureArticles: [ScreenshotFixture.Article] = []
            for article in selected {
                let summary = summaryExcerpt(for: article)
                fixtureArticles.append(
                    ScreenshotFixture.Article(
                        title: article.title,
                        url: article.url,
                        author: article.author,
                        summary: summary,
                        date: article.date,
                        blocks: article.blocks
                    )
                )
                allImageHashes.formUnion(imageHashes(in: article.blocks))
            }

            if let logoHash = feed.logoHash {
                allImageHashes.insert(logoHash)
            }

            fixtureFeeds.append(
                ScreenshotFixture.Feed(
                    name: spec.name,
                    identifier: spec.url,
                    tagName: spec.tagName,
                    tagColorHex: spec.tagColorHex,
                    logoHash: feed.logoHash,
                    articles: fixtureArticles
                )
            )
        }

        guard !fixtureFeeds.isEmpty else {
            NSLog("ScreenshotFixtureCollector: no feeds produced usable content, aborting export")
            return
        }

        let (anchorFeedIndex, anchorArticleIndex) = pickAnchor(in: fixtureFeeds)

        let fixture = ScreenshotFixture(
            feeds: fixtureFeeds,
            images: [],
            anchorFeedIndex: anchorFeedIndex,
            anchorArticleIndex: anchorArticleIndex
        )

        await export(fixture: fixture, imageHashes: allImageHashes)
    }

    /// `article.summary` is populated only when AI post-processing is enabled; the collection run
    /// has no AI configured, so this always falls back to a plain-text excerpt of the article's
    /// own opening — NOT an AI-generated summary. It exists purely so the reader's SUMMARY block
    /// has real content to render in screenshots.
    private static func summaryExcerpt(for article: Article) -> String {
        if !article.summary.isEmpty { return article.summary }
        return excerpt(from: article.plainText, maxLength: 180)
    }

    private static func excerpt(from text: String, maxLength: Int) -> String {
        let trimmedSource = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSource.count > maxLength else { return trimmedSource }

        let cutIndex = trimmedSource.index(trimmedSource.startIndex, offsetBy: maxLength)
        let head = String(trimmedSource[trimmedSource.startIndex..<cutIndex])

        for terminator in [". ", "! ", "? "] {
            if let range = head.range(of: terminator, options: .backwards) {
                return String(head[head.startIndex..<range.lowerBound]) + "."
            }
        }
        if let range = head.range(of: " ", options: .backwards) {
            return String(head[head.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Regex-scans the JSON encoding of a block tree for every `yana-img://<hash>` reference —
    /// covers lead images, inline images, and embed poster images uniformly, without needing to
    /// walk the recursive `Block` enum case-by-case.
    private static func imageHashes(in blocks: [Block]) -> Set<String> {
        // `.withoutEscapingSlashes` is essential: the default encoder writes `yana-img:\/\/…`,
        // which the literal `//` in the pattern below would never match — silently dropping every
        // body image from the export.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(blocks),
              let json = String(data: data, encoding: .utf8) else { return [] }

        let pattern = #"yana-img://([0-9a-fA-F]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: json, range: NSRange(json.startIndex..., in: json))

        var hashes = Set<String>()
        for match in matches {
            guard let range = Range(match.range(at: 1), in: json) else { continue }
            hashes.insert(String(json[range]))
        }
        return hashes
    }

    /// Picks the hero article for the reader's initial anchor: the first feed+article (in
    /// selection order) whose blocks start with an image and whose title is non-trivial.
    private static func pickAnchor(in feeds: [ScreenshotFixture.Feed]) -> (feedIndex: Int, articleIndex: Int) {
        for (feedIndex, feed) in feeds.enumerated() {
            for (articleIndex, article) in feed.articles.enumerated() {
                guard case .image = article.blocks.first else { continue }
                guard article.title.trimmingCharacters(in: .whitespaces).count > 8 else { continue }
                return (feedIndex, articleIndex)
            }
        }
        return (0, 0)
    }

    @MainActor
    private static func export(fixture: ScreenshotFixture, imageHashes: Set<String>) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            NSLog("ScreenshotFixtureCollector: could not resolve Documents directory")
            return
        }

        let root = documents.appendingPathComponent("ScreenshotFixture", isDirectory: true)
        let imagesDir = root.appendingPathComponent("images", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        } catch {
            NSLog("ScreenshotFixtureCollector: failed to create output directories: \(error)")
            return
        }

        // Resolve every referenced image by scanning the on-disk cache directory for a file whose
        // content-hash stem matches. This is deliberately NOT `ImageStore.shared.fileURL(forHash:)`:
        // body images are written by the aggregation pipeline's own `ImageStore` instance, so
        // `.shared`'s in-memory extension map doesn't know their extension. Those writes can also
        // still be flushing when we reach here, so we settle briefly and retry the scan for any
        // hash not yet present.
        let cachesImagesDir = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ))?.appendingPathComponent("images")

        func indexCache() -> [String: URL] {
            guard let dir = cachesImagesDir,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { return [:] }
            return Dictionary(files.map { ($0.deletingPathExtension().lastPathComponent, $0) },
                              uniquingKeysWith: { first, _ in first })
        }

        // The aggregation pipeline's body-image downloads are not fully awaited by
        // `forceReload`, so they can still be landing on disk when we get here. Poll the cache
        // directory until every referenced hash is present (or a generous timeout), re-scanning
        // each second.
        var cachedFilesByHash = indexCache()
        for _ in 0..<60 where !imageHashes.isSubset(of: Set(cachedFilesByHash.keys)) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            cachedFilesByHash = indexCache()
        }
        let stillMissing = imageHashes.subtracting(Set(cachedFilesByHash.keys))
        if !stillMissing.isEmpty {
            NSLog("ScreenshotFixtureCollector: \(stillMissing.count) image(s) never appeared on disk after polling")
        }

        var collectedImages: [ScreenshotFixture.Image] = []
        for hash in imageHashes.sorted() {
            guard let sourceURL = cachedFilesByHash[hash] else {
                NSLog("ScreenshotFixtureCollector: WARNING image missing for hash \(hash), skipping")
                continue
            }
            do {
                let data = try Data(contentsOf: sourceURL)
                let ext = sourceURL.pathExtension
                let destURL = imagesDir.appendingPathComponent("\(hash).\(ext)")
                try data.write(to: destURL)
                collectedImages.append(ScreenshotFixture.Image(hash: hash, ext: ext))
            } catch {
                NSLog("ScreenshotFixtureCollector: WARNING failed to copy image \(hash): \(error)")
            }
        }

        var finalFixture = fixture
        finalFixture.images = collectedImages

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(finalFixture)
            let manifestURL = root.appendingPathComponent("manifest.json")
            try data.write(to: manifestURL)
            NSLog(
                "ScreenshotFixtureCollector: wrote manifest + \(collectedImages.count) images to \(root.path)"
            )
        } catch {
            NSLog("ScreenshotFixtureCollector: failed to write manifest: \(error)")
        }
    }
}
#endif
