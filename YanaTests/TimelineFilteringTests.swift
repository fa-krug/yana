import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Timeline filtering + anchor")
struct TimelineFilteringTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Article.self, Feed.self, Yana.Tag.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// `Article.filterTagNames` resolves live: `feed?.tagIDs` joined against every synced
    /// `Tag`'s `serverID`. An `Article` outside a `ModelContext` (no `feed`, or no context to
    /// fetch `Tag` rows from) always reads as untagged -- so the article/feed/tags below must
    /// all be inserted for the join to resolve anything.
    private func article(_ id: String, tagIDs: [Int], in context: ModelContext) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        let feed = Feed(name: "Feed-\(id)", identifier: "feed-\(id)")
        feed.tagIDs = tagIDs
        a.feed = feed
        context.insert(feed)
        context.insert(a)
        return a
    }

    @Test func untaggedRespectsToggle() throws {
        let context = try makeContext()
        let a = article("a", tagIDs: [], in: context)
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: true).count == 1)
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: false).isEmpty)
    }

    @Test func showsArticleWithAnyActiveTag() throws {
        let context = try makeContext()
        let tech = Yana.Tag(name: "Tech")
        tech.serverID = 1
        let fun = Yana.Tag(name: "Fun")
        fun.serverID = 2
        context.insert(tech)
        context.insert(fun)
        let a = article("a", tagIDs: [1, 2], in: context)
        // Tech disabled but Fun active -> still shown.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech"], includeUntagged: true).count == 1)
        // Both disabled -> hidden.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech", "Fun"], includeUntagged: true).isEmpty)
    }

    @Test func starredOnlyFiltersOutUnstarred() throws {
        let context = try makeContext()
        let starred = article("a", tagIDs: [], in: context)
        starred.starred = true
        let unstarred = article("b", tagIDs: [], in: context)
        #expect(StarredFilter.apply(to: [starred, unstarred], starredOnly: false).count == 2)
        #expect(StarredFilter.apply(to: [starred, unstarred], starredOnly: true).map(\.identifier) == ["a"])
    }

    @Test func readFilterNarrowsToUnreadOrRead() throws {
        let context = try makeContext()
        let read = article("a", tagIDs: [], in: context)
        read.read = true
        let unread = article("b", tagIDs: [], in: context)
        #expect(ReadFilter.apply(to: [read, unread], mode: .all).count == 2)
        #expect(ReadFilter.apply(to: [read, unread], mode: .unread).map(\.identifier) == ["b"])
        #expect(ReadFilter.apply(to: [read, unread], mode: .read).map(\.identifier) == ["a"])
    }

    /// The whole point of the exemption: an article is marked read the instant it becomes the
    /// displayed one, so without this the article the user is reading would drop out of the
    /// timeline under them the moment "Unread" was selected.
    @Test func readFilterKeepsTheExemptArticleWhicheverModeIsOn() throws {
        let context = try makeContext()
        let displayed = article("a", tagIDs: [], in: context)
        displayed.read = true
        displayed.serverID = 7
        let unread = article("b", tagIDs: [], in: context)
        let out = ReadFilter.apply(to: [displayed, unread], mode: .unread, exemptKey: displayed.stableKey)
        #expect(out.map(\.identifier) == ["a", "b"])
        // ...and the same article is kept in `.read` mode once it is the unread one.
        displayed.read = false
        #expect(ReadFilter.apply(to: [displayed], mode: .read, exemptKey: displayed.stableKey).count == 1)
        // A *different* article's key exempts nothing.
        #expect(ReadFilter.apply(to: [displayed], mode: .read, exemptKey: unread.stableKey).isEmpty)
    }

    /// The exemption is keyed by `stableKey`, so two feeds sharing one `identifier` (a legitimate
    /// case -- `identifier` is only a per-feed dedup key) don't exempt each other.
    @Test func readFilterExemptionDoesNotLeakAcrossArticlesSharingAnIdentifier() throws {
        let context = try makeContext()
        let displayed = article("dup", tagIDs: [], in: context)
        displayed.serverID = 1
        displayed.read = true
        let other = Article(title: "dup", identifier: "dup", url: "https://y.com/dup")
        other.serverID = 2
        other.read = true
        context.insert(other)
        let out = ReadFilter.apply(to: [displayed, other], mode: .unread, exemptKey: displayed.stableKey)
        #expect(out.map(\.serverID) == [1])
    }

    @Test func filterChainAppliesEveryFilterAtOnce() throws {
        let context = try makeContext()
        let tag = Yana.Tag(name: "Keep")
        tag.serverID = 1
        context.insert(tag)
        let kept = article("kept", tagIDs: [1], in: context)
        kept.starred = true
        let wrongTag = article("wrongTag", tagIDs: [], in: context)
        wrongTag.starred = true
        let unstarred = article("unstarred", tagIDs: [1], in: context)
        let alreadyRead = article("read", tagIDs: [1], in: context)
        alreadyRead.starred = true
        alreadyRead.read = true

        let out = TimelineFilterChain.apply(
            to: [kept, wrongTag, unstarred, alreadyRead],
            disabledTagNames: [], includeUntagged: false, disabledFeedNames: [],
            starredOnly: true, readFilter: .unread, anchorKey: nil
        )
        #expect(out.map(\.identifier) == ["kept"])
    }

    @Test func filterChainReadsEveryInputFromSettings() throws {
        let context = try makeContext()
        let displayed = article("a", tagIDs: [], in: context)
        displayed.read = true
        let read = article("b", tagIDs: [], in: context)
        read.read = true
        let unread = article("c", tagIDs: [], in: context)

        let suite = "TimelineFilteringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.readFilter = .unread
        settings.timelineAnchorIdentifier = displayed.identifier

        let out = TimelineFilterChain.apply(to: [displayed, read, unread], settings: settings)
        // "a" survives as the anchored article, "b" is filtered out, "c" is unread.
        #expect(out.map(\.identifier) == ["a", "c"])
    }

    @Test func filterReadMirrorsReadOnArticleAndSummary() throws {
        let context = try makeContext()
        let a = article("a", tagIDs: [], in: context)
        a.read = true
        #expect(a.filterRead == true)

        let summary = ArticleSummary(a)
        #expect(summary.filterRead == true)
        #expect(summary.filterRead == summary.isRead)
    }

    @Test func emptyFilterReturnsAllItemsIncludingUntagged() throws {
        let context = try makeContext()
        let tagged = article("a", tagIDs: [], in: context)
        let untagged = article("b", tagIDs: [], in: context)
        let out = TagFilter.apply(to: [tagged, untagged], disabledTagNames: [], includeUntagged: true)
        #expect(out.count == 2)
    }

    @Test func anchorResolvesToIndexOrNewest() throws {
        let context = try makeContext()
        let a = article("a", tagIDs: [], in: context)
        let b = article("b", tagIDs: [], in: context)
        let list = [a, b]
        #expect(TimelineAnchor.index(for: "a", in: list) == 0)
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        // No / missing memory falls back to the newest article (last in the ascending timeline),
        // not the oldest, so a first launch opens on fresh content.
        #expect(TimelineAnchor.index(for: "missing", in: list) == 1)
        #expect(TimelineAnchor.index(for: nil, in: list) == 1)
        #expect(TimelineAnchor.index(for: nil, in: [] as [Article]) == 0)
    }
}
