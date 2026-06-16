import Foundation
import Testing
@testable import Yana

@Suite("OPMLCodec")
struct OPMLCodecTests {
    @Test func encodesFeedAsOutlineWithYanaAttributes() {
        let feed = OPMLFeed(
            name: "Heise",
            identifier: "https://www.heise.de/rss/heise-atom.xml",
            aggregatorType: "heise",
            optionsJSONBase64: "eyJhIjoxfQ==",
            tags: ["Tech", "News"],
            dailyLimit: 20,
            enabled: true
        )
        let xml = OPMLCodec.encode([feed])
        #expect(xml.contains("<opml"))
        #expect(xml.contains("xmlns:yana"))
        #expect(xml.contains("text=\"Heise\""))
        #expect(xml.contains("xmlUrl=\"https://www.heise.de/rss/heise-atom.xml\""))
        #expect(xml.contains("yana:aggregatorType=\"heise\""))
        #expect(xml.contains("yana:tags=\"Tech,News\""))
        #expect(xml.contains("yana:dailyLimit=\"20\""))
        #expect(xml.contains("yana:enabled=\"true\""))
    }

    @Test func escapesSpecialCharactersInAttributes() {
        let feed = OPMLFeed(name: "A & B \"C\"", identifier: "http://x?a=1&b=2",
                            aggregatorType: "feed_content", optionsJSONBase64: "", tags: [], dailyLimit: 10, enabled: true)
        let xml = OPMLCodec.encode([feed])
        #expect(xml.contains("A &amp; B &quot;C&quot;"))
        #expect(xml.contains("a=1&amp;b=2"))
    }

    @Test func decodeRoundTripsYanaFeed() {
        let feed = OPMLFeed(name: "Heise", identifier: "https://www.heise.de/rss/heise-atom.xml",
                            aggregatorType: "heise", optionsJSONBase64: "eyJhIjoxfQ==",
                            tags: ["Tech", "News"], dailyLimit: 20, enabled: true)
        let decoded = OPMLCodec.decode(OPMLCodec.encode([feed]))
        #expect(decoded == [feed])
    }

    @Test func decodeForeignOpmlYieldsNoYanaMetadata() {
        let xml = """
        <?xml version="1.0"?>
        <opml version="2.0"><body>
          <outline text="Some Blog" type="rss" xmlUrl="https://example.com/feed.xml" />
        </body></opml>
        """
        let decoded = OPMLCodec.decode(xml)
        #expect(decoded.count == 1)
        #expect(decoded[0].name == "Some Blog")
        #expect(decoded[0].identifier == "https://example.com/feed.xml")
        #expect(decoded[0].aggregatorType == nil)
        #expect(decoded[0].tags.isEmpty)
    }

    @Test func decodeHandlesNestedOutlines() {
        let xml = """
        <opml version="2.0"><body>
          <outline text="Folder">
            <outline text="Inner" type="rss" xmlUrl="https://a.com/f.xml" />
          </outline>
        </body></opml>
        """
        let decoded = OPMLCodec.decode(xml)
        #expect(decoded.map(\.identifier) == ["https://a.com/f.xml"])
    }

    @Test func decodeReturnsEmptyForMalformedXML() {
        #expect(OPMLCodec.decode("not xml at all <<<").isEmpty)
    }
}
