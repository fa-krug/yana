import Foundation

/// Produces the reader's summary block. Two implementations, selected by `AppSettings.aiMode`:
/// `ServerAISummaryProvider` (network, via the server's configured provider) and
/// `AppleIntelligenceSummaryProvider` (on-device). Both degrade to `nil` on any failure --
/// "no summary available" is an expected, silent outcome here (rate limit, no provider
/// configured, model unavailable), never a user-facing error.
protocol AISummaryProvider: Sendable {
    func summarize(content: String, title: String) async -> String?
}

/// Whether the reader's "Summarize" action should be offered at all, for a given mode.
/// `.server` is always considered ready -- `ServerAISummaryProvider` degrades to `nil` on its
/// own if the server has no provider configured, which is a fine outcome for a button that was
/// visible; `.appleIntelligence` needs an actual on-device-model availability check, since
/// showing the button with no usable model is a worse experience than hiding it. Shared here so
/// `ReaderHostView`/`TimelineModel`'s toolbar-visibility checks (Task 17) don't duplicate the
/// same three-line switch in two files.
enum AISummaryReadiness {
    static func isReady(mode: AIMode) -> Bool {
        switch mode {
        case .server: true
        case .appleIntelligence: AppleIntelligenceClient().availability == .available
        }
    }
}

private struct AIPromptBody: Encodable { let prompt: String }
private struct AIPromptResponse: Decodable { let response: String; let provider: String; let model: String }

struct ServerAISummaryProvider: AISummaryProvider {
    let client: YanaAPIClient

    func summarize(content: String, title: String) async -> String? {
        let prompt = "Summarize the following article concisely in 2-3 sentences.\n\nTitle: \(title)\n\n\(content)"
        do {
            let result: AIPromptResponse = try await client.post("/api/v1/ai/prompt", body: AIPromptBody(prompt: prompt))
            return result.response
        } catch {
            // 429 (daily/monthly limit), 409 (no provider configured), 502 (provider error) all
            // land here as ordinary, expected "no summary this time" outcomes.
            return nil
        }
    }
}

struct AppleIntelligenceSummaryProvider: AISummaryProvider {
    let generator: ArticleGenerating

    init(generator: ArticleGenerating = AppleIntelligenceClient()) {
        self.generator = generator
    }

    func summarize(content: String, title: String) async -> String? {
        guard generator.availability == .available else { return nil }
        return await AppleIntelligenceChunkedSummarizer.summarize(html: content, title: title, generator: generator)
    }
}
