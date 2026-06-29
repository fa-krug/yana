import Foundation
import SwiftData

/// One-time background sweep that converts articles still holding legacy pre-migration HTML
/// (`Article.content`) into the native `[Block]` model. Runs off the launch/render critical path
/// in its own `@ModelActor` context: the `BlockParser` SwiftSoup parse is the exact cost the native
/// reader removes from cold start, so reconverting must never happen lazily on read.
///
/// New articles never set `content` (they store blocks directly at import), so this sweep only ever
/// touches the pre-upgrade backlog. Retention (~1 month) bounds that set, making the sweep small and
/// self-clearing — once every legacy row is converted (and its `content` cleared) it finds nothing.
@ModelActor
actor BlockMigrator {
    /// Convert legacy rows in bounded batches so a large backlog never holds the context (or memory)
    /// for one giant transaction. Returns the total number of articles converted.
    func migrate(batchSize: Int = 200) throws -> Int {
        var converted = 0
        while true {
            var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.content != "" })
            descriptor.fetchLimit = batchSize
            let rows = try modelContext.fetch(descriptor)
            if rows.isEmpty { break }
            for article in rows {
                let blocks = BlockParser.blocks(fromHTML: article.content, baseURL: URL(string: article.url))
                article.blocks = blocks       // updates blockData + plainText
                article.content = ""          // clear the legacy HTML so it isn't re-swept
            }
            try modelContext.save()
            converted += rows.count
            if rows.count < batchSize { break }
        }
        return converted
    }
}

/// Kicks the one-time legacy-HTML → blocks conversion as a low-priority background task.
enum BlockMigration {
    static func run(container: ModelContainer) {
        Task.detached(priority: .utility) {
            let migrator = BlockMigrator(modelContainer: container)
            _ = try? await migrator.migrate()
        }
    }
}
