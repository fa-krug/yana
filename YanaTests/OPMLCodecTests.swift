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
}
