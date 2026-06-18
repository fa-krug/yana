import Foundation
import Testing
@testable import Yana

@Suite("FeedParser")
struct FeedParserTests {
    private let rss = """
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <item>
          <title>First</title>
          <link>https://ex.com/1</link>
          <author>Alice</author>
          <pubDate>Wed, 02 Oct 2002 13:00:00 GMT</pubDate>
          <description>Desc one</description>
          <content:encoded xmlns:content="http://purl.org/rss/1.0/modules/content/"><![CDATA[<p>Full one</p>]]></content:encoded>
          <enclosure url="https://ex.com/1.mp3" type="audio/mpeg"/>
          <itunes:duration>1:01:01</itunes:duration>
        </item>
      </channel>
    </rss>
    """

    private let atom = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <title>Atom Title</title>
        <link href="https://ex.com/a1"/>
        <author><name>Bob</name></author>
        <updated>2003-12-13T18:30:02Z</updated>
        <content type="html">&lt;p&gt;Atom body&lt;/p&gt;</content>
      </entry>
    </feed>
    """

    @Test func parsesRssItemFields() throws {
        let feed = try FeedParser.parse(Data(rss.utf8))
        let entry = try #require(feed.entries.first)
        #expect(entry.title == "First")
        #expect(entry.link == "https://ex.com/1")
        #expect(entry.author == "Alice")
        #expect(entry.content?.contains("Full one") == true)
        #expect(entry.entryDescription?.contains("Desc one") == true)
        #expect(entry.enclosures.first?.url == "https://ex.com/1.mp3")
        #expect(entry.enclosures.first?.type == "audio/mpeg")
        #expect(entry.itunesDuration == "1:01:01")
        #expect(entry.published != nil)
    }

    @Test func parsesAtomEntryFields() throws {
        let feed = try FeedParser.parse(Data(atom.utf8))
        let entry = try #require(feed.entries.first)
        #expect(entry.title == "Atom Title")
        #expect(entry.link == "https://ex.com/a1")
        #expect(entry.author == "Bob")
        #expect(entry.content?.contains("Atom body") == true)
        #expect(entry.published != nil)
    }

    private let atomMultiLink = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <title>Multi</title>
        <link rel="alternate" href="https://ex.com/article"/>
        <link rel="self" href="https://ex.com/feed.xml"/>
        <updated>2003-12-13T18:30:02Z</updated>
        <content type="html">body</content>
      </entry>
    </feed>
    """

    @Test func atomPrefersAlternateLinkOverSelf() throws {
        let feed = try FeedParser.parse(Data(atomMultiLink.utf8))
        let entry = try #require(feed.entries.first)
        #expect(entry.link == "https://ex.com/article")
    }

    // MARK: - Date parsing

    @Test func parsesRfc822WithoutSeconds() {
        // Some feeds omit the seconds component.
        #expect(FeedParser.parseDate("Wed, 02 Oct 2002 13:00 GMT") != nil)
        #expect(FeedParser.parseDate("Wed, 02 Oct 2002 13:00 +0000") != nil)
    }

    @Test func parsesDateOnly() {
        // Date-only values (no time) should still resolve, not fall back to "now".
        #expect(FeedParser.parseDate("2024-06-18") != nil)
    }

    @Test func parsesIso8601WithOffset() {
        #expect(FeedParser.parseDate("2003-12-13T18:30:02+02:00") != nil)
    }

    @Test func returnsNilForUnparseableDate() {
        #expect(FeedParser.parseDate("not a date") == nil)
        #expect(FeedParser.parseDate("") == nil)
        #expect(FeedParser.parseDate(nil) == nil)
    }

    private let atomPublishedAndUpdated = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <title>Both Dates</title>
        <link href="https://ex.com/both"/>
        <updated>2021-01-01T00:00:00Z</updated>
        <published>2020-01-01T00:00:00Z</published>
        <content type="html">body</content>
      </entry>
    </feed>
    """

    @Test func prefersPublishedOverUpdated() throws {
        // The timeline sorts by the article's actual publication date, so the
        // original <published> must win over the later <updated>, regardless of
        // their order in the XML.
        let feed = try FeedParser.parse(Data(atomPublishedAndUpdated.utf8))
        let entry = try #require(feed.entries.first)
        let published = try #require(entry.published)
        let expected = try #require(FeedParser.parseDate("2020-01-01T00:00:00Z"))
        #expect(published == expected)
    }
}
