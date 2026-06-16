import Foundation
import SwiftData

/// Maps SwiftData `Feed`s to/from OPML via `OPMLCodec`. Import resolves tags by name,
/// restores typed options when present, falls back to `feedContent` for foreign OPML, and
/// dedupes against existing feeds by `(identifier, aggregatorType)`.
@MainActor
enum FeedPortability {
    struct ImportResult: Equatable {
        var imported: Int
        var skipped: Int
    }

    // MARK: Export

    static func exportOPML(context: ModelContext) -> String {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return OPMLCodec.encode(feeds.map(opmlFeed(from:)))
    }

    private static func opmlFeed(from feed: Feed) -> OPMLFeed {
        let optionsB64: String = {
            guard let data = try? JSONEncoder().encode(feed.options) else { return "" }
            return data.base64EncodedString()
        }()
        return OPMLFeed(
            name: feed.name,
            identifier: feed.identifier,
            aggregatorType: feed.aggregatorType,
            optionsJSONBase64: optionsB64,
            tags: feed.tags.filter { !$0.isBuiltIn }.map(\.name),
            dailyLimit: feed.dailyLimit,
            enabled: feed.enabled
        )
    }

    // MARK: Import

    @discardableResult
    static func importOPML(_ xml: String, context: ModelContext) -> ImportResult {
        let dtos = OPMLCodec.decode(xml)
        let existing = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        var existingKeys = Set(existing.map { "\($0.identifier)|\($0.aggregatorType)" })

        var imported = 0
        var skipped = 0
        for dto in dtos {
            let type = dto.aggregatorType.flatMap(AggregatorType.init(rawValue:)) ?? .feedContent
            let key = "\(dto.identifier)|\(type.rawValue)"
            if existingKeys.contains(key) { skipped += 1; continue }

            let feed = Feed(
                name: dto.name,
                aggregatorType: type,
                identifier: dto.identifier,
                dailyLimit: dto.dailyLimit ?? 20,
                enabled: dto.enabled ?? true,
                options: decodeOptions(dto.optionsJSONBase64, type: type)
            )
            feed.tags = resolveTags(dto.tags, context: context)
            context.insert(feed)
            existingKeys.insert(key)
            imported += 1
        }
        try? context.save()
        return ImportResult(imported: imported, skipped: skipped)
    }

    private static func decodeOptions(_ base64: String, type: AggregatorType) -> AggregatorOptions {
        guard !base64.isEmpty,
              let data = Data(base64Encoded: base64),
              let options = try? JSONDecoder().decode(AggregatorOptions.self, from: data)
        else { return type.defaultOptions }
        return options
    }

    /// Resolve tag names to `Tag`s, reusing existing (case-insensitive) matches and creating
    /// missing ones. Never creates or attaches the built-in Starred tag.
    private static func resolveTags(_ names: [String], context: ModelContext) -> [Tag] {
        guard !names.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        var byName = Dictionary(all.filter { !$0.isBuiltIn }.map { ($0.name.lowercased(), $0) },
                                uniquingKeysWith: { first, _ in first })
        var result: [Tag] = []
        for name in names {
            let key = name.lowercased()
            if let tag = byName[key] {
                result.append(tag)
            } else {
                let tag = Tag(name: name)
                context.insert(tag)
                byName[key] = tag
                result.append(tag)
            }
        }
        return result
    }
}
