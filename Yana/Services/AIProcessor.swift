import Foundation

/// Applies optional AI post-processing to a batch of aggregated articles. Off-main,
/// `Sendable`, no SwiftData. Ported from the server's `_apply_ai_processing`.
protocol AIProcessing: Sendable {
    /// Returns the processed list. When AI is disabled / unconfigured, returns `input`
    /// unchanged. On per-article AI failure or invalid JSON, that article is DROPPED.
    func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle]
}

/// Concrete processor. Holds an `AIConfig` snapshot and a text generator (defaults to an
/// `AIClient`, but tests inject a fake). `requestDelay` is the per-article pause (seconds).
struct AIProcessor: AIProcessing {
    typealias Generate = @Sendable (_ prompt: String, _ jsonMode: Bool) async throws -> String

    /// Upper bound on simultaneous in-flight AI requests. Caps overlap so a large batch does
    /// not fan out to unbounded concurrent provider calls.
    static let maxConcurrentAIRequests = 3

    let config: AIConfig
    let requestDelay: Int
    let generate: Generate

    /// Default: drive a real `AIClient` built from the snapshot.
    init(config: AIConfig, requestDelay: Int) {
        self.config = config
        self.requestDelay = requestDelay
        let client = AIClient(config: config)
        self.generate = client.generate
    }

    /// Injectable generator for tests.
    init(config: AIConfig, requestDelay: Int, generate: @escaping Generate) {
        self.config = config
        self.requestDelay = requestDelay
        self.generate = generate
    }

    func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
        // Gate: at least one toggle on, a concrete provider, and a non-empty key.
        let anyEnabled = ai.summarize || ai.improveWriting || ai.translate
        guard anyEnabled, config.provider != .none, !config.apiKey.isEmpty else {
            return input
        }

        // Results indexed by input position so order is preserved regardless of completion order.
        var results = [AggregatedArticle?](repeating: nil, count: input.count)
        let cap = min(Self.maxConcurrentAIRequests, input.count)

        await withTaskGroup(of: (Int, AggregatedArticle?).self) { group in
            var launched = 0

            // Launch one article's request, spacing launches by `requestDelay` to respect
            // provider rate limits (the responses still overlap).
            func launch(_ i: Int) async {
                if i > 0, requestDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(requestDelay) * 1_000_000_000)
                }
                let article = input[i]
                group.addTask { (i, await self.processOne(article, ai: ai)) }
            }

            while launched < cap, !Task.isCancelled {
                await launch(launched)
                launched += 1
            }

            while let (index, value) = await group.next() {
                results[index] = value
                if Task.isCancelled { break }   // a newer run cancelled this one — stop launching
                if launched < input.count {
                    await launch(launched)
                    launched += 1
                }
            }
        }

        return results.compactMap { $0 }
    }

    /// Process a single article. Returns it unchanged when content is empty (server parity),
    /// the AI-updated article on success, or `nil` to DROP it (invalid JSON or AI failure).
    private func processOne(_ article: AggregatedArticle, ai: AIOptions) async -> AggregatedArticle? {
        guard !article.content.isEmpty else { return article }
        let cleanHTML = ArticleAIText.cap((try? ArticleAIText.stripChrome(article.content)) ?? article.content)
        let prompt = Self.buildPrompt(title: article.title, cleanHTML: cleanHTML, ai: ai)
        do {
            let raw = try await generate(prompt, true)
            guard let parsed = Self.extractJSON(raw) else { return nil }
            var updated = article
            if let title = parsed["title"] as? String { updated.title = title }
            if let content = parsed["content"] as? String { updated.content = content }
            if let summary = parsed["summary"] as? String { updated.summary = summary }
            return updated
        } catch {
            return nil
        }
    }

    // MARK: - Prompt assembly (exact server instruction strings)

    static func buildPrompt(title: String, cleanHTML: String, ai: AIOptions) -> String {
        var parts: [String] = []

        let keyList = ai.summarize ? "'title', 'content', and 'summary'" : "'title' and 'content'"
        parts.append(
            "You are an AI assistant that processes article content. "
            + "You will receive an article title and content in HTML format. "
            + "You must return the result as a JSON object with keys \(keyList). "
            + "Do not include any markdown formatting (like ```json) in the response, just the raw JSON string."
        )

        if ai.summarize {
            parts.append(
                ArticleAIText.summarizeInstruction
                + " Put this summary in the 'summary' key. "
                + "Keep the 'content' field as the full article HTML — do not replace the content with the summary."
            )
        }

        if ai.improveWriting {
            parts.append(ArticleAIText.improveWritingInstruction)
        }

        if ai.translate {
            parts.append(ArticleAIText.translateInstruction(language: ai.translateLanguage))
        }

        parts.append(
            "The input content is HTML with stripped headers/footers. "
            + "CRITICAL: Preserve ALL HTML tags and structure in your output. "
            + "This includes: links (<a>), paragraphs (<p>), headings (<h1>-<h6>), lists (<ul>, <ol>, <li>), "
            + "images (<img>), divs, spans, and all other HTML elements. "
            + "Your output 'content' field must be valid HTML with the exact same structure as the input."
        )

        let inputData: [String: String] = ["title": title, "content": cleanHTML]
        let inputJSON = (try? JSONSerialization.data(withJSONObject: inputData, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return parts.joined(separator: "\n") + "\n\nInput Data:\n" + inputJSON
    }

    // MARK: - Robust JSON extraction (direct -> ```json``` block -> first{..last})

    static func extractJSON(_ raw: String) -> [String: Any]? {
        if let parsed = parseObject(raw) { return parsed }

        // ```json ... ``` (or plain ``` ... ```) fenced block.
        if let fenced = firstFencedJSON(in: raw), let parsed = parseObject(fenced) {
            return parsed
        }

        // First '{' to last '}'.
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end {
            let candidate = String(raw[start...end])
            if let parsed = parseObject(candidate) { return parsed }
        }
        return nil
    }

    private static func parseObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Compiled once: ```` ```(?:json)?\s*(\{.*?\})\s*``` ```` (DOTALL via `[\s\S]`).
    private static let fencedJSONRegex = try? NSRegularExpression(
        pattern: "```(?:json)?\\s*(\\{[\\s\\S]*?\\})\\s*```"
    )

    /// Mirrors the server regex ```` ```(?:json)?\s*(\{.*?\})\s*``` ```` (DOTALL).
    private static func firstFencedJSON(in raw: String) -> String? {
        guard let regex = fencedJSONRegex else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: raw)
        else { return nil }
        return String(raw[captured])
    }
}
