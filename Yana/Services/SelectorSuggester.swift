import Foundation

/// Which selector list the AI is generating.
enum SelectorKind: Sendable {
    case content
    case ignore
}

/// Suggests CSS selectors for the full-website extraction editor by asking the configured AI
/// provider to read a sample article page and return a selector list for one kind at a time.
///
/// Split into pure, unit-testable pieces (instruction/prompt building + tolerant parsing) and a
/// thin `@MainActor` runner that resolves the provider, fetches a sample page, and calls the model.
enum SelectorSuggester {
    // MARK: - Pure prompt building

    static func instructions(for kind: SelectorKind) -> String {
        switch kind {
        case .content:
            return "You are a web-scraping assistant. Given the HTML of a news/blog article page, "
                + "identify the CSS selectors that select the main article content container(s) — "
                + "the headline body text, not navigation, headers, footers, sidebars, comments, or ads."
        case .ignore:
            return "You are a web-scraping assistant. Given the HTML of a news/blog article page, "
                + "identify the CSS selectors for noise that should be removed from the article body — "
                + "ads, share buttons, related-article widgets, newsletter prompts, and similar clutter."
        }
    }

    /// The user-message prompt: the (capped, chrome-stripped) page HTML, the current selectors to
    /// validate, and a strict output contract. `jsonMode` providers still benefit from the explicit
    /// shape; Apple Intelligence (free-form) relies on it.
    static func prompt(for kind: SelectorKind, pageHTML: String, current: [String]) -> String {
        let capped = ArticleAIText.cap(pageHTML)
        let candidates = current.isEmpty ? "(none)" : current.joined(separator: ", ")
        return """
        Return ONLY a JSON object of the form {"selectors": ["sel1", "sel2"]} with the CSS \
        selectors, most specific first. Do not include any prose.

        Existing candidate selectors (keep the ones still appropriate, drop the rest, add better ones):
        \(candidates)

        Article page HTML:
        \(capped)
        """
    }

    // MARK: - Pure parsing

    /// Tolerant extraction of a selector list from a model reply. Accepts a bare JSON object
    /// (`{"selectors": [...]}`), a bare JSON array, or the first such structure embedded in prose.
    /// Trims, drops empties, and de-duplicates while preserving order.
    static func parseSelectors(from text: String) -> [String] {
        let raw = firstJSONFragment(in: text) ?? text
        guard let data = raw.data(using: .utf8) else { return [] }

        var list: [String] = []
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            if let dict = obj as? [String: Any], let arr = dict["selectors"] as? [Any] {
                list = arr.compactMap { $0 as? String }
            } else if let arr = obj as? [Any] {
                list = arr.compactMap { $0 as? String }
            }
        }
        var seen = Set<String>()
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first `{...}` or `[...]` fragment in `text`, so a model that wraps JSON in prose or
    /// ```json fences still parses. Balanced-delimiter scan over the first opener found.
    private static func firstJSONFragment(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = chars[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        for i in start..<chars.count {
            if chars[i] == open { depth += 1 }
            else if chars[i] == close {
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            }
        }
        return nil
    }

    // MARK: - Orchestration

    enum SuggestError: Error {
        case noProvider          // no usable AI provider configured
        case noSampleArticle     // couldn't resolve a sample article page to analyze
    }

    /// Resolve the active provider, fetch a sample article page via the website aggregator, ask the
    /// model for the requested list, and return the parsed selectors. Throws `SuggestError` /
    /// underlying network/AI errors on failure. Runs on the main actor to read settings/Keychain,
    /// hopping off for the network + model calls.
    @MainActor
    static func suggest(kind: SelectorKind, identifier: String, options: AggregatorOptions,
                        current: [String], settings: AppSettings) async throws -> [String] {
        let provider = settings.activeAIProvider
        guard provider != .none else { throw SuggestError.noProvider }

        // Fetch a sample article page through the same path the aggregator uses (feed discovery
        // included), so the selectors are derived from a real article, not the index page.
        let config = FeedConfig(type: .fullWebsite, identifier: identifier,
                                dailyLimit: 1, options: options, collectedToday: 0)
        let aggregator = FullWebsiteAggregator(config: config, credentials: AggregatorCredentials())
        let pageHTML = try await sampleArticleHTML(from: aggregator)

        let instr = instructions(for: kind)
        let userPrompt = prompt(for: kind, pageHTML: pageHTML, current: current)

        let text: String
        if provider == .appleIntelligence {
            let client = AppleIntelligenceClient()
            guard client.availability == .available else { throw SuggestError.noProvider }
            text = try await client.generateText(instructions: instr, prompt: userPrompt,
                                                 temperature: 0.2, maxTokens: 500)
        } else {
            let aiConfig = AggregationService.makeAIConfig(settings: settings)
            guard !aiConfig.apiKey.isEmpty else { throw SuggestError.noProvider }
            let combined = instr + "\n\n" + userPrompt
            // jsonMode is intentionally off: the Gemini path pins a fixed article-shaped response
            // schema in jsonMode, which would prevent a selector list. The explicit prompt +
            // tolerant `parseSelectors` recover the JSON regardless of provider.
            text = try await AIClient(config: aiConfig).generate(prompt: combined, jsonMode: false)
        }
        return parseSelectors(from: text)
    }

    /// The first article's page HTML from a website aggregator's feed (discovery included).
    private static func sampleArticleHTML(from aggregator: FullWebsiteAggregator) async throws -> String {
        let entries = try await aggregator.fetchEntries()
        guard let link = entries.first?.link, !link.isEmpty else { throw SuggestError.noSampleArticle }
        return try await aggregator.fetchArticleHTML(link)
    }
}
