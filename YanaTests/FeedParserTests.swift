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
}
