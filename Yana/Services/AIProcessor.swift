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

        var output: [AggregatedArticle] = []
        for (i, article) in input.enumerated() {
            if Task.isCancelled { break }   // background run expired — stop making network calls
            if i > 0, requestDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(requestDelay) * 1_000_000_000)
            }

            // Empty content: keep unchanged, do not call AI (server parity).
            guard !article.content.isEmpty else {
                output.append(article)
                continue
            }

            let cleanHTML = ArticleAIText.cap((try? ArticleAIText.stripChrome(article.content)) ?? article.content)
            let prompt = Self.buildPrompt(title: article.title, cleanHTML: cleanHTML, ai: ai)

            do {
                let raw = try await generate(prompt, true)
                guard let parsed = Self.extractJSON(raw) else { continue }   // drop on invalid JSON
                var updated = article
                if let title = parsed["title"] as? String { updated.title = title }
                if let content = parsed["content"] as? String { updated.content = content }
                output.append(updated)
            } catch {
                continue        // drop on AI failure
            }
        }
        return output
    }

    // MARK: - Prompt assembly (exact server instruction strings)

    static func buildPrompt(title: String, cleanHTML: String, ai: AIOptions) -> String {
        var parts: [String] = []

        parts.append(
            "You are an AI assistant that processes article content. "
            + "You will receive an article title and content in HTML format. "
            + "You must return the result as a JSON object with keys 'title' and 'content'. "
            + "Do not include any markdown formatting (like ```json) in the response, just the raw JSON string."
        )

        if ai.summarize {
            parts.append(ArticleAIText.summarizeInstruction)
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

    /// Mirrors the server regex ```` ```(?:json)?\s*(\{.*?\})\s*``` ```` (DOTALL).
    private static func firstFencedJSON(in raw: String) -> String? {
        let pattern = "```(?:json)?\\s*(\\{[\\s\\S]*?\\})\\s*```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: raw)
        else { return nil }
        return String(raw[captured])
    }
}
