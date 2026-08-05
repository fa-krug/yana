import Foundation

/// The server's wire format for an article's content, matching
/// `yana-server/src/lib/aggregators/blocks/schema.ts` exactly: a `type`-discriminated union,
/// **not** the shape `Block`'s compiler-synthesized `Codable` would produce on its own (that
/// synthesis encodes each case as `{"<caseName>": ...}` with no `type` field at all). This file
/// is the translation layer — `Block`/`InlineRun`/`Embed` themselves are untouched, since the
/// reader's existing block-rendering code depends on their current in-memory shape.
struct WireDocument: Decodable {
    let version: Int
    let blocks: [Block]

    private enum CodingKeys: String, CodingKey { case version, blocks }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        blocks = try container.decode([WireBlockBox].self, forKey: .blocks).map(\.block)
    }
}

/// Decodes one server `WireBlock` object into the app's `Block` enum. A private wrapper (rather
/// than a `Block` extension) because `Block` itself must keep its existing synthesized
/// `Codable` for anything that still round-trips it in-memory (nothing currently does, but
/// changing `Block`'s own conformance is a larger, riskier edit than adding this translation
/// layer next to it).
private struct WireBlockBox: Decodable {
    let block: Block

    private enum TypeKey: String, CodingKey { case type }
    private enum ParagraphKeys: String, CodingKey { case runs }
    private enum HeadingKeys: String, CodingKey { case level, runs }
    private enum ListKeys: String, CodingKey { case ordered, items }
    private enum BlockquoteKeys: String, CodingKey { case blocks }
    private enum ImageKeys: String, CodingKey { case ref, caption }
    private enum EmbedKeys: String, CodingKey { case provider, thumbnailRef, externalURL, title }
    private enum CodeBlockKeys: String, CodingKey { case text, language }

    init(from decoder: any Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        let type = try typeContainer.decode(String.self, forKey: .type)
        switch type {
        case "paragraph":
            let c = try decoder.container(keyedBy: ParagraphKeys.self)
            block = .paragraph(try c.decode([WireInlineRun].self, forKey: .runs).map(\.run))
        case "heading":
            let c = try decoder.container(keyedBy: HeadingKeys.self)
            block = .heading(
                level: try c.decode(Int.self, forKey: .level),
                runs: try c.decode([WireInlineRun].self, forKey: .runs).map(\.run)
            )
        case "list":
            let c = try decoder.container(keyedBy: ListKeys.self)
            let items = try c.decode([[WireBlockBox]].self, forKey: .items)
            block = .list(ordered: try c.decode(Bool.self, forKey: .ordered), items: items.map { $0.map(\.block) })
        case "blockquote":
            let c = try decoder.container(keyedBy: BlockquoteKeys.self)
            block = .blockquote(try c.decode([WireBlockBox].self, forKey: .blocks).map(\.block))
        case "image":
            let c = try decoder.container(keyedBy: ImageKeys.self)
            block = .image(
                ref: try c.decode(String.self, forKey: .ref),
                caption: try c.decode([WireInlineRun].self, forKey: .caption).map(\.run)
            )
        case "embed":
            let c = try decoder.container(keyedBy: EmbedKeys.self)
            let providerRaw = try c.decode(String.self, forKey: .provider)
            block = .embed(Embed(
                provider: Embed.Provider(rawValue: providerRaw) ?? .generic,
                thumbnailRef: try c.decodeIfPresent(String.self, forKey: .thumbnailRef),
                externalURL: try c.decode(String.self, forKey: .externalURL),
                title: try c.decodeIfPresent(String.self, forKey: .title)
            ))
        case "codeBlock":
            let c = try decoder.container(keyedBy: CodeBlockKeys.self)
            block = .codeBlock(
                text: try c.decode(String.self, forKey: .text),
                language: try c.decodeIfPresent(String.self, forKey: .language)
            )
        case "divider":
            block = .divider
        default:
            // Server's own extensibility rule: an unknown block type is skipped, never fatal.
            // Represent it as an empty paragraph rather than failing the whole document decode.
            block = .paragraph([])
        }
    }
}

private struct WireInlineRun: Decodable {
    let run: InlineRun

    private enum CodingKeys: String, CodingKey { case text, styles, link }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .text)
        let link = try c.decodeIfPresent(String.self, forKey: .link)
        let styleNames = try c.decode([String].self, forKey: .styles)
        var styles: InlineStyle = []
        for name in styleNames {
            switch name {
            case "bold": styles.insert(.bold)
            case "italic": styles.insert(.italic)
            case "code": styles.insert(.code)
            case "strikethrough": styles.insert(.strikethrough)
            default: break   // unknown style name ignored, per the server's own extensibility rule
            }
        }
        run = InlineRun(text: text, styles: styles, link: link)
    }
}
