import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("PodcastAggregator")
struct PodcastAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    final class StubPodcast: PodcastAggregator, @unchecked Sendable {
        let entries: [FeedEntry]
        init(entries: [FeedEntry], options: PodcastOptions, store: ImageStore) {
            self.entries = entries
            super.init(config: FeedConfig(type: .podcast, identifier: "https://p.com/feed", dailyLimit: 20,
                                          options: .podcast(options), collectedToday: 0),
                       credentials: .init(), store: store)
        }
        override func fetchEntries() async throws -> [FeedEntry] { entries }
    }

    private func entry(enclosures: [FeedEnclosure], duration: String? = "1:02:03",
                       itunesImage: String? = "https://p.com/art.jpg") -> FeedEntry {
        FeedEntry(title: "Ep 1", link: "https://p.com/1", content: nil,
                  summary: "<p>Notes</p>", entryDescription: nil, published: .now, author: "Host",
                  enclosures: enclosures, itunesDuration: duration, itunesImage: itunesImage, mediaThumbnails: [])
    }

    @Test func buildsPlayerArtworkDurationAndNotes() async throws {
        let e = entry(enclosures: [FeedEnclosure(url: "https://p.com/1.mp3", type: "audio/mpeg")])
        let agg = StubPodcast(entries: [e], options: PodcastOptions(), store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(a.content.contains("<audio controls"))
        #expect(a.content.contains("https://p.com/1.mp3"))
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))    // artwork cached
        #expect(a.content.contains("Duration: 1:02:03"))
        #expect(a.content.contains("Download Episode"))
        #expect(a.content.contains("Show Notes"))
        #expect(a.content.contains("Notes"))
    }

    @Test func skipsEpisodesWithoutAudioEnclosure() async throws {
        let e = entry(enclosures: [FeedEnclosure(url: "https://p.com/1.pdf", type: "application/pdf")])
        let agg = StubPodcast(entries: [e], options: PodcastOptions(), store: tempStore())
        #expect(try await agg.aggregate().isEmpty)
    }

    @Test func gatesPlayerAndDownloadLink() async throws {
        var opts = PodcastOptions(); opts.includePlayer = false; opts.includeDownloadLink = false
        let e = entry(enclosures: [FeedEnclosure(url: "https://p.com/1.m4a", type: nil)])  // by extension
        let agg = StubPodcast(entries: [e], options: opts, store: tempStore())
        let a = try #require(try await agg.aggregate().first)
        #expect(!a.content.contains("<audio"))
        #expect(!a.content.contains("Download Episode"))
        #expect(a.content.contains("Show Notes"))
    }

    @Test func parsesSecondsAndMinuteSecondDurations() async throws {
        let e1 = entry(enclosures: [FeedEnclosure(url: "https://p.com/a.mp3", type: "audio/mpeg")], duration: "125")
        let a1 = try #require(try await StubPodcast(entries: [e1], options: PodcastOptions(), store: tempStore()).aggregate().first)
        #expect(a1.content.contains("Duration: 2:05"))
        let e2 = entry(enclosures: [FeedEnclosure(url: "https://p.com/b.mp3", type: "audio/mpeg")], duration: "5:09")
        let a2 = try #require(try await StubPodcast(entries: [e2], options: PodcastOptions(), store: tempStore()).aggregate().first)
        #expect(a2.content.contains("Duration: 5:09"))
    }
}
