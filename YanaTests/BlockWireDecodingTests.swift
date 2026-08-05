import Foundation
import Testing
@testable import Yana

@Suite("BlockWireDecoding")
struct BlockWireDecodingTests {
    @Test func decodesAParagraphWithStyledRuns() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"paragraph","runs":[{"text":"Hello ","styles":[],"link":null},{"text":"world","styles":["bold","italic"],"link":"https://example.com"}]}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        #expect(doc.version == 1)
        guard case .paragraph(let runs) = doc.blocks.first else { Issue.record("expected paragraph"); return }
        #expect(runs[0] == InlineRun(text: "Hello ", styles: [], link: nil))
        #expect(runs[1] == InlineRun(text: "world", styles: [.bold, .italic], link: "https://example.com"))
    }

    @Test func decodesHeadingListBlockquoteDivider() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"heading","level":2,"runs":[{"text":"Title","styles":[],"link":null}]},
            {"type":"list","ordered":true,"items":[[{"type":"paragraph","runs":[{"text":"one","styles":[],"link":null}]}]]},
            {"type":"blockquote","blocks":[{"type":"paragraph","runs":[{"text":"quoted","styles":[],"link":null}]}]},
            {"type":"divider"}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        #expect(doc.blocks.count == 4)
        guard case .heading(let level, let runs) = doc.blocks[0] else { Issue.record("expected heading"); return }
        #expect(level == 2)
        #expect(runs.first?.text == "Title")
        guard case .list(let ordered, let items) = doc.blocks[1] else { Issue.record("expected list"); return }
        #expect(ordered)
        #expect(items.count == 1)
        guard case .blockquote(let inner) = doc.blocks[2] else { Issue.record("expected blockquote"); return }
        #expect(inner.count == 1)
        guard case .divider = doc.blocks[3] else { Issue.record("expected divider"); return }
    }

    @Test func decodesImageEmbedCodeBlock() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"image","ref":"yana-img://abc123","caption":[]},
            {"type":"embed","provider":"youtube","thumbnailRef":"yana-img://thumb1","externalURL":"https://youtube.com/watch?v=x","title":"A Video"},
            {"type":"codeBlock","text":"let x = 1","language":"swift"}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        guard case .image(let ref, let caption) = doc.blocks[0] else { Issue.record("expected image"); return }
        #expect(ref == "yana-img://abc123")
        #expect(caption.isEmpty)
        guard case .embed(let embed) = doc.blocks[1] else { Issue.record("expected embed"); return }
        #expect(embed.provider == .youtube)
        #expect(embed.title == "A Video")
        guard case .codeBlock(let text, let language) = doc.blocks[2] else { Issue.record("expected codeBlock"); return }
        #expect(text == "let x = 1")
        #expect(language == "swift")
    }

    @Test func unknownStyleNameIsIgnoredNotFatal() throws {
        let json = #"""
        {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"x","styles":["bold","madeUpStyle"],"link":null}]}]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        guard case .paragraph(let runs) = doc.blocks.first else { Issue.record("expected paragraph"); return }
        #expect(runs.first?.styles == [.bold])
    }

    @Test func unknownEmbedProviderFallsBackToGenericNotFatal() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"embed","provider":"someFutureProvider","thumbnailRef":null,"externalURL":"https://example.com","title":null}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        guard case .embed(let embed) = doc.blocks.first else { Issue.record("expected embed"); return }
        #expect(embed.provider == .generic)
        #expect(embed.externalURL == "https://example.com")
    }

    @Test func unknownBlockTypeIsSkippedNotFatal() throws {
        let json = #"""
        {"version":1,"blocks":[
            {"type":"paragraph","runs":[{"text":"before","styles":[],"link":null}]},
            {"type":"someFutureBlockType","whatever":"data"},
            {"type":"paragraph","runs":[{"text":"after","styles":[],"link":null}]}
        ]}
        """#.data(using: .utf8)!
        let doc = try JSONDecoder().decode(WireDocument.self, from: json)
        #expect(doc.blocks.count == 3)
        guard case .paragraph(let middle) = doc.blocks[1] else { Issue.record("expected fallback paragraph"); return }
        #expect(middle.isEmpty)
    }
}
