#if DEBUG
import Foundation
import SwiftData

/// Curated, network-free library for App Store screenshots. Gated by the
/// `-UITEST_SCREENSHOTS` launch argument so it never runs on a normal launch or on the
/// `YANA_SEED_ARTICLES` performance path. Idempotent: bails if any Feed already exists.
///
/// Replays a frozen `ScreenshotFixture` snapshot of REAL feed content — collected once, offline,
/// by `ScreenshotFixtureCollector` — bundled at `Resources/ScreenshotFixture/manifest.json` (+
/// `images/<hash>.<ext>`, flattened to the bundle root at build time).
enum ScreenshotSeed {
    static let launchArgument = "-UITEST_SCREENSHOTS"

    @MainActor
    static func seedIfRequested(into context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        await seed(into: context)
    }

    @MainActor
    static func seed(into context: ModelContext) async {
        // Idempotency guard.
        if let existing = try? context.fetch(FetchDescriptor<Feed>()), !existing.isEmpty { return }

        guard let manifestURL = Bundle.main.url(forResource: "manifest", withExtension: "json") else {
            NSLog("ScreenshotSeed: manifest.json not found in bundle")
            return
        }
        let fixture: ScreenshotFixture
        do {
            let data = try Data(contentsOf: manifestURL)
            fixture = try JSONDecoder().decode(ScreenshotFixture.self, from: data)
        } catch {
            NSLog("ScreenshotSeed: failed to load/decode manifest: \(error)")
            return
        }

        // Re-insert every image. Content-addressed storage means re-storing the same bytes
        // reproduces the same hash the fixture's `yana-img://<hash>` refs already point at.
        for image in fixture.images {
            guard let imageURL = Bundle.main.url(forResource: image.hash, withExtension: image.ext) else {
                NSLog("ScreenshotSeed: image \(image.hash).\(image.ext) not found in bundle, skipping")
                continue
            }
            do {
                let data = try Data(contentsOf: imageURL)
                _ = await ImageStore.shared.storeData(data, ext: image.ext)
            } catch {
                NSLog("ScreenshotSeed: failed to load image \(image.hash).\(image.ext): \(error)")
            }
        }

        var globalIndex = 0
        var articleIdentifiers: [String] = []
        var anchorIdentifier: String?
        var tagsByName: [String: Tag] = [:]

        for (feedIndex, fixtureFeed) in fixture.feeds.enumerated() {
            let feed = Feed(name: fixtureFeed.name, aggregatorType: .feedContent,
                            identifier: fixtureFeed.identifier)
            feed.logoHash = fixtureFeed.logoHash
            context.insert(feed)

            let tag: Tag
            if let existingTag = tagsByName[fixtureFeed.tagName] {
                tag = existingTag
            } else {
                tag = Tag(name: fixtureFeed.tagName, colorHex: fixtureFeed.tagColorHex)
                context.insert(tag)
                tagsByName[fixtureFeed.tagName] = tag
            }
            feed.tags = [tag]

            for (articleIndex, fixtureArticle) in fixtureFeed.articles.enumerated() {
                let identifier = "screenshot://\(feedIndex)/\(articleIndex)"
                let article = Article(
                    title: Self.decodingEntities(fixtureArticle.title),
                    identifier: identifier,
                    url: fixtureArticle.url,
                    date: fixtureArticle.date,
                    author: Self.decodingEntities(fixtureArticle.author),
                    summary: Self.decodingEntities(fixtureArticle.summary)
                )
                article.blocks = fixtureArticle.blocks
                article.createdAt = Date(timeIntervalSinceNow: -Double(globalIndex) * 5400)
                article.feed = feed
                article.tags = [tag]
                context.insert(article)
                articleIdentifiers.append(identifier)

                if feedIndex == fixture.anchorFeedIndex && articleIndex == fixture.anchorArticleIndex {
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

    /// Decodes HTML entities in feed-supplied text. RSS/Atom titles arrive with entities like
    /// `&#8217;` (right single quote) that the generic `FeedParser` does not decode, so the frozen
    /// snapshot carries them verbatim — decode here so screenshots show clean text. Named entities
    /// are resolved first so a double-encoded `&amp;#8217;` collapses correctly.
    private static func decodingEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&nbsp;", "\u{00A0}"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"),
            ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities: &#8217; (decimal) and &#x2019; (hex).
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                  let isHexRange = Range(match.range(at: 1), in: result),
                  let digitsRange = Range(match.range(at: 2), in: result) else { continue }
            let isHex = !result[isHexRange].isEmpty
            let digits = String(result[digitsRange])
            guard let code = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(full, with: String(scalar))
        }
        return result
    }
}
#endif
