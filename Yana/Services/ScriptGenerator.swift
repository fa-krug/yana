import Foundation

/// Generates raw text (here, JavaScript) from a system instruction + user prompt. One abstraction
/// over the cloud providers (`AIClient`) and on-device Apple Intelligence, so the script generator
/// works with whichever provider the user has configured. Injectable for hermetic tests.
protocol ScriptTextGenerating: Sendable {
    func generate(instructions: String, prompt: String) async throws -> String
}

/// Cloud-provider backing: routes through `AIClient` (OpenAI/Anthropic/Gemini/…). `AIClient` has
/// no separate system role, so the instructions are prepended to the prompt.
struct CloudScriptGenerator: ScriptTextGenerating {
    let config: AIConfig
    var fetch: AIClient.Fetch = AIClient.defaultFetch

    func generate(instructions: String, prompt: String) async throws -> String {
        let combined = instructions + "\n\n" + prompt
        return try await AIClient(config: config, fetch: fetch).generate(prompt: combined, jsonMode: false)
    }
}

/// On-device backing via Apple Intelligence guided generation.
struct AppleIntelligenceScriptGenerator: ScriptTextGenerating {
    var client = AppleIntelligenceClient()
    var temperature: Double = 0.2
    var maxTokens: Int = 2000

    func generate(instructions: String, prompt: String) async throws -> String {
        try await client.generateScript(instructions: instructions, prompt: prompt,
                                         temperature: temperature, maxTokens: maxTokens)
    }
}

/// Result of an authoring run: the generated script, the first-emit preview (if any), and an
/// error message when the script could not be made to emit an article within the self-heal budget.
struct ScriptGenerationResult: Sendable {
    var source: String
    var preview: ScriptRunResult?
    var error: String?
}

/// Authors a custom-feed script from a natural-language brief. Fetches the seed URL at design time
/// to show the model the real page/response shape (reduced by `ScriptContextReducer`), generates a
/// script, test-runs it in `ScriptEngine` (stopping at the first emit), and self-heals up to
/// `maxSelfHeal` times by feeding back the error — escalating to a fetched detail-page sample when
/// items are found but their content is empty (the "two-pass" authoring, realized as a heal step).
struct ScriptGenerator: Sendable {
    let textGenerator: ScriptTextGenerating
    var engine: ScriptEngine = ScriptEngine()
    /// Design-time fetch used to sample the seed/detail pages for the model. Defaults to the same
    /// `HTTPClient`-backed bridge the runtime uses; injectable for tests.
    var httpGet: ScriptEngine.HTTPGet = ScriptEngine.defaultHTTPGet
    var maxSelfHeal: Int = 2

    func generate(brief: String, seedURL: String) async throws -> ScriptGenerationResult {
        let seedSample = await sample(of: seedURL)
        var detailSample: String?
        var lastError: String?
        var source = ""
        var best: ScriptRunResult?

        for attempt in 0...maxSelfHeal {
            let prompt = Self.buildPrompt(brief: brief, seedURL: seedURL, seedSample: seedSample,
                                          detailSample: detailSample,
                                          priorSource: attempt == 0 ? nil : source,
                                          priorError: lastError)
            source = Self.extractCode(try await textGenerator.generate(instructions: Self.baseInstructions, prompt: prompt))

            do {
                let run = try await engine.run(source: source, input: .init(url: seedURL, secret: ""), maxArticles: 1)
                guard let first = run.articles.first else {
                    lastError = String(localized: "The script ran but produced no articles.")
                        + (run.logs.isEmpty ? "" : " Logs: " + run.logs.joined(separator: " | "))
                    continue
                }
                best = run
                // Success once an article carries content, or when the heal budget is spent.
                if !first.html.isEmpty || attempt == maxSelfHeal {
                    return ScriptGenerationResult(source: source, preview: run, error: nil)
                }
                // Items found but empty content: fetch a real detail page for the next pass.
                detailSample = await sample(of: first.url)
                lastError = "Articles were found but their `html` content was empty. Improve how the article body is fetched/extracted."
            } catch let error as ScriptError {
                lastError = error.errorDescription ?? String(localized: "The script failed to run.")
            }
        }
        return ScriptGenerationResult(source: source, preview: best, error: lastError)
    }

    // MARK: - Design-time sampling

    private func sample(of urlString: String) async -> String {
        guard !urlString.isEmpty else { return "(no URL provided)" }
        let response = await httpGet(urlString, "GET", [:], nil)
        guard let body = response.body else {
            return "(could not fetch \(urlString): \(response.error ?? "unknown error"))"
        }
        return ScriptContextReducer.reduce(body: body, contentType: nil)
    }

    // MARK: - Prompt building

    static func buildPrompt(brief: String, seedURL: String, seedSample: String,
                            detailSample: String?, priorSource: String?, priorError: String?) -> String {
        var parts: [String] = []
        parts.append("The feed's seed URL (available to the script as input.url) is:\n\(seedURL)")
        parts.append("What the user wants this feed to collect:\n\(brief)")
        parts.append("A reduced sample of the seed URL's response (use it to find articles):\n```\n\(seedSample)\n```")
        if let detailSample {
            parts.append("A reduced sample of one article's detail page (use it to extract title/body/date):\n```\n\(detailSample)\n```")
        }
        if let priorSource, let priorError {
            parts.append("Your previous script did not work. Fix it.\nError: \(priorError)\nPrevious script:\n```javascript\n\(priorSource)\n```")
        }
        parts.append("Return the complete, corrected JavaScript only.")
        return parts.joined(separator: "\n\n")
    }

    /// Strip Markdown code fences a model may wrap the script in.
    static func extractCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: "\n")
        lines.removeFirst()                                   // opening ``` or ```javascript
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Provider selection

    /// Build the text generator for the user's active AI provider, or `nil` when AI is off.
    @MainActor
    static func makeTextGenerator(settings: AppSettings) -> ScriptTextGenerating? {
        let config = AggregationService.makeAIConfig(settings: settings)
        switch config.provider {
        case .none:
            return nil
        case .appleIntelligence:
            return AppleIntelligenceScriptGenerator(temperature: config.temperature, maxTokens: config.maxTokens)
        default:
            return CloudScriptGenerator(config: config)
        }
    }

    // MARK: - Base instructions (the contract the runtime enforces)

    static let baseInstructions = """
    You write small JavaScript programs that build a custom news feed for the Yana app. Your output \
    is RAW JavaScript only — no Markdown fences, no commentary.

    CONTRACT
    - Define a function `run(input)`. `input.url` is the feed's seed URL; `input.secret` is an \
    optional user secret (e.g. an API key) — may be an empty string.
    - For each article, call `Yana.emit({ ... })`. You may instead `return` an array of the same \
    objects. Emit objects use these fields:
      • title  (string, required)
      • url    (string, required — also the article's unique id)
      • html   (string, optional — the raw article HTML; Yana sanitizes it and localizes images)
      • date   (number of epoch-millis, or an ISO date string, optional)
      • author (string, optional)
      • iconURL(string, optional)
    - You produce DATA only. Do not build final/styled HTML; Yana sanitizes, caches images, rewrites \
    embeds, and applies the reader theme afterward.

    AVAILABLE API (the ONLY capabilities — there is no fetch/XMLHttpRequest, no DOM, no file access)
    - Yana.httpGet(url, options?) -> string. options = { method, headers, body }. Throws on failure; \
    wrap in try/catch if needed. Use JSON.parse(...) for JSON APIs.
    - Yana.select(html, cssSelector) -> array of nodes. Each node has: .text (string), .html \
    (string), .attrs (object of attributes), and .attr(name) -> string.
    - Yana.parseFeed(xmlString) -> array of { title, link, content, author, date(ms) } for RSS/Atom.
    - Yana.parseDate(string) -> epoch-millis number (or null). Use it for human/ISO date strings.
    - Yana.log(...) for debugging; output appears in the preview.

    GUIDELINES
    - Keep it efficient: fetch the listing once; only fetch article detail pages when the body isn't \
    already present in the listing.
    - Prefer robust selectors. Skip items you can't parse rather than throwing.

    EXAMPLE — JSON API
    function run(input) {
      var data = JSON.parse(Yana.httpGet(input.url));
      data.items.forEach(function (p) {
        Yana.emit({ title: p.title, url: p.link, html: p.body_html, date: Yana.parseDate(p.published) });
      });
    }

    EXAMPLE — HTML scrape
    function run(input) {
      var list = Yana.httpGet(input.url);
      Yana.select(list, "article a.headline").forEach(function (a) {
        var url = a.attr("href");
        var page = Yana.httpGet(url);
        var body = Yana.select(page, ".entry-content")[0];
        Yana.emit({ title: a.text, url: url, html: body ? body.html : "" });
      });
    }
    """
}
