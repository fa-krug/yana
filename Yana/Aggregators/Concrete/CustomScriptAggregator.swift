import Foundation

/// A user-built feed driven by a data-only JavaScript (see `ScriptEngine`). The script emits raw
/// articles from any source (HTML scrape, JSON/RSS API, …); this aggregator maps them to
/// `FeedEntry`s and lets the standard `RSSPipelineAggregator` pipeline finish the job — sanitizing
/// the HTML, localizing images to `yana-img://`, rewriting embeds, and (later) running AI. The
/// script never touches the final reader HTML, so it cannot bypass those safety rails.
///
/// `refetch` (single-article reload) re-runs the script and re-enriches the matching item, exactly
/// like the base RSS pipeline.
final class CustomScriptAggregator: RSSPipelineAggregator, @unchecked Sendable {
    private let engine: ScriptEngine
    /// Stop the script after this many emits (`1` for the editor's Try preview); `nil` = unlimited.
    private let maxArticles: Int?
    /// Emitted articles keyed by URL, so `makeArticle` can restore fields the `FeedEntry` can't carry.
    private var scriptArticlesByURL: [String: ScriptArticle] = [:]

    init(config: FeedConfig, credentials: AggregatorCredentials, store: ImageStore = .shared,
         engine: ScriptEngine = ScriptEngine(), maxArticles: Int? = nil) {
        self.engine = engine
        self.maxArticles = maxArticles
        super.init(config: config, credentials: credentials, store: store)
    }

    private var scriptOptions: CustomScriptOptions {
        if case .customScript(let options) = config.options { return options }
        return CustomScriptOptions()
    }

    override func validate() throws {
        try super.validate()   // identifier must be non-empty
        if scriptOptions.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AggregatorError.parse("the custom script is empty")
        }
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let input = ScriptEngine.Input(url: config.identifier, secret: credentials.scriptSecret ?? "")
        let result: ScriptRunResult
        do {
            result = try await engine.run(source: scriptOptions.source, input: input, maxArticles: maxArticles)
        } catch let error as ScriptError {
            throw AggregatorError.parse(error.errorDescription ?? "script failed")
        }
        scriptArticlesByURL = Dictionary(result.articles.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        return result.articles.map { article in
            var entry = FeedEntry()
            entry.title = article.title
            entry.link = article.url
            entry.content = article.html
            entry.author = article.author
            entry.published = article.date
            return entry
        }
    }

    override func makeArticle(from entry: FeedEntry) -> AggregatedArticle {
        var article = super.makeArticle(from: entry)
        if let scriptArticle = scriptArticlesByURL[entry.link],
           let icon = scriptArticle.iconURL, !icon.isEmpty {
            article.iconURL = icon
        }
        return article
    }
}
