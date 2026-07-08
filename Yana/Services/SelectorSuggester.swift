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
                + "identify the CSS selectors for noise that should be removed from the article body. "
                + "Be thorough and list a selector for EVERY distinct noise block you can find, including: "
                + "advertisements and sponsored/affiliate blocks (often labeled 'Anzeige', 'Advertisement', "
                + "'Sponsored', or carrying class names containing 'ad', 'advert', 'promo', 'affiliate', "
                + "'sponsor', 'commercial'); share/social buttons; newsletter and subscription prompts; "
                + "related-, recommended-, and most-read-article widgets; author bios; comment counters; "
                + "and 'back to homepage'/breadcrumb navigation. Prefer stable class or attribute "
                + "selectors over auto-generated hash class names."
        }
    }

    /// Strip the bulk that carries no structural signal — scripts, styles, inline SVG, templates,
    /// and the document `<head>` — so the character cap is spent on real, class-bearing body markup.
    /// Without this a large page (e.g. golem.de) buries the article body and its noise blocks past
    /// the cap, and the model never sees the elements it is asked to select. Falls back to the
    /// original HTML if parsing fails.
    static func compactForAnalysis(_ html: String) -> String {
        guard let doc = try? HTMLUtils.parse(html) else { return html }
        for sel in ["script", "style", "noscript", "svg", "template", "head"] {
            if let els = try? doc.select(sel) { for el in els { try? el.remove() } }
        }
        return (try? doc.html()) ?? html
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
    /// (`{"selectors": [...]}`), a bare JSON array, or such a structure embedded in prose.
    /// Trims, drops empties, and de-duplicates while preserving order.
    ///
    /// A "be thorough" ignore-list reply often opens with reasoning prose that itself contains a
    /// bracketed fragment (an enumerated list like `[ads, share buttons]`, or a `{…}`) *before* the
    /// real JSON object. Trusting the first bracket found would hand that unparseable prose to
    /// `JSONSerialization`, yield nothing, and surface as "the AI returned no selectors" — even
    /// though the model did answer. So try the whole text first, then every balanced JSON fragment
    /// in order, returning the first that actually produces selectors.
    static func parseSelectors(from text: String) -> [String] {
        for candidate in [text] + jsonFragments(in: text) {
            let list = selectors(fromJSON: candidate)
            if !list.isEmpty { return list }
        }
        return []
    }

    /// Parse a single JSON string into a cleaned selector list (object with a `selectors` array or
    /// a bare array). Returns empty when the string isn't the expected JSON shape.
    private static func selectors(fromJSON raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var list: [String] = []
        if let dict = obj as? [String: Any], let arr = dict["selectors"] as? [Any] {
            list = arr.compactMap { $0 as? String }
        } else if let arr = obj as? [Any] {
            list = arr.compactMap { $0 as? String }
        }
        var seen = Set<String>()
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Every balanced `{...}` or `[...]` fragment in `text`, in order, so a model that wraps JSON in
    /// prose or ```json fences still parses even when leading prose contains stray brackets. Each
    /// fragment counts only its own delimiter type; scanning resumes past a closed fragment. A
    /// never-closed opener (e.g. JSON truncated by the token cap) ends the scan.
    private static func jsonFragments(in text: String) -> [String] {
        let chars = Array(text)
        var fragments: [String] = []
        var i = 0
        while i < chars.count {
            let open = chars[i]
            guard open == "{" || open == "[" else { i += 1; continue }
            let close: Character = open == "{" ? "}" : "]"
            var depth = 0
            var j = i
            var closed = false
            while j < chars.count {
                if chars[j] == open { depth += 1 }
                else if chars[j] == close {
                    depth -= 1
                    if depth == 0 { closed = true; break }
                }
                j += 1
            }
            guard closed else { break }
            fragments.append(String(chars[i...j]))
            i = j + 1
        }
        return fragments
    }

    // MARK: - Orchestration

    enum SuggestError: Error {
        case noProvider          // no usable AI provider configured
        case noSampleArticle     // couldn't resolve a sample article page to analyze
        case sampleFetchFailed   // network/parse error loading the sample article page
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
        // included), so the selectors are derived from a real article, not the index page. The
        // identifier here is the editor's live text field, which for a not-yet-saved feed can be a
        // scheme-less domain like `golem.de` — `URL(string:)` would then yield a host-less URL and
        // the fetch would fail. Fill in the scheme first, exactly as save/preview do.
        let config = FeedConfig(type: .fullWebsite, identifier: FeedURLResolver.normalized(identifier),
                                dailyLimit: 1, options: options, collectedToday: 0)
        let aggregator = FullWebsiteAggregator(config: config, credentials: AggregatorCredentials())
        let sampleHTML: String
        do {
            sampleHTML = try await sampleArticleHTML(from: aggregator)
        } catch let error as SuggestError {
            throw error                              // already precise (e.g. .noSampleArticle)
        } catch {
            throw SuggestError.sampleFetchFailed     // network/parse — distinct from an AI failure
        }
        let pageHTML = compactForAnalysis(sampleHTML)

        let instr = instructions(for: kind)

        let text: String
        if provider == .appleIntelligence {
            let client = AppleIntelligenceClient()
            guard client.availability == .available else { throw SuggestError.noProvider }
            // The on-device model has a ~4096-token context window. The cloud-sized 50k-char page
            // cap overflows it, so `respond` throws and the whole request fails (summaries survive
            // only because they chunk to fit). Truncate the page to the on-device content budget so
            // the model actually sees markup it can select from. ~3 chars/token, conservative to
            // leave room for the instructions, the candidate list, and the model's reply.
            let budgetChars = AppleIntelligenceProcessor.contentBudgetTokens * 3
            let applePrompt = prompt(for: kind, pageHTML: String(pageHTML.prefix(budgetChars)),
                                     current: current)
            text = try await client.generateText(instructions: instr, prompt: applePrompt,
                                                 temperature: 0.2, maxTokens: 500)
        } else {
            let aiConfig = AggregationService.makeAIConfig(settings: settings)
            guard !aiConfig.apiKey.isEmpty else { throw SuggestError.noProvider }
            let combined = instr + "\n\n" + prompt(for: kind, pageHTML: pageHTML, current: current)
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
