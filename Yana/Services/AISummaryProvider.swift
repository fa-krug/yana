import Foundation

/// Why a summary could not be produced. These map to distinct, actionable toasts: the old
/// "collapse every failure into `nil`" design told the user to "try again" even for causes where
/// retrying can never work (no provider configured on the server, or an article longer than the
/// server's configured AI prompt limit, whose default of 500 characters is shorter than any real
/// article body, so server-mode summarization failed every single time with no hint why).
enum AISummaryFailure: Error, Equatable, Sendable {
    /// Server rejected the prompt for exceeding its configured `Max Prompt Length`.
    case promptTooLong
    /// Server has no AI provider configured.
    case noProvider
    /// Server's daily/monthly AI request limit is reached.
    case limitReached
    /// The configured provider itself failed (bad credentials, upstream error).
    case providerError
    /// Everything else: offline, timed out, unexpected wire shape, on-device model unavailable or
    /// failing. `detail` names which of those it was (never localized -- it is a diagnostic tag,
    /// shown in parentheses) so a self-hosted operator can tell a network drop from a wire-shape
    /// mismatch from a server error code this app does not know about.
    case unavailable(detail: String?)
}

/// Produces the reader's summary block. Two implementations, selected by `AppSettings.aiMode`:
/// `ServerAISummaryProvider` (network, via the server's configured provider) and
/// `AppleIntelligenceSummaryProvider` (on-device). Neither throws: a failure comes back as an
/// `AISummaryFailure` the call sites turn into a toast.
protocol AISummaryProvider: Sendable {
    func summarize(content: String, title: String) async -> Result<String, AISummaryFailure>
}

/// Whether the reader's "Summarize" action should be offered at all, for a given mode.
/// `.server` is always considered ready -- the app cannot know the server's AI configuration
/// without asking, so a failed attempt reports the server's own reason (`AISummaryFailure`,
/// rendered by `ReaderActions.summarizeFailureMessage`) instead of hiding the button; `.appleIntelligence` needs an actual on-device-model availability check, since
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

    /// The server spends up to its own `aiRequestTimeout` (default 120s) per provider attempt, so
    /// `URLSession`'s 60s default aborted slow generations before they ever came back. This does
    /// not cover the server's absolute worst case (every retry timing out), deliberately: a reader
    /// action that spins for ten minutes is worse than one that gives up and says so.
    static let requestTimeout: TimeInterval = 180

    func summarize(content: String, title: String) async -> Result<String, AISummaryFailure> {
        // The server's limit applies to the WHOLE prompt string, so cap the assembled prompt --
        // capping only `content` let the instruction and title push a max-length body back over
        // the limit and straight into `prompt_too_long`.
        let header = "Summarize the following article concisely in 2-3 sentences.\n\nTitle: \(title)\n\n"
        let prompt = ArticleAIText.cap(header + content)
        do {
            let result: AIPromptResponse = try await client.post(
                "/api/v1/ai/prompt", body: AIPromptBody(prompt: prompt), timeout: Self.requestTimeout
            )
            return .success(result.response)
        } catch let error as YanaAPIClientError {
            return .failure(Self.failure(for: error))
        } catch {
            return .failure(.unavailable(detail: "unexpected"))
        }
    }

    /// Maps the server's `{ error: { code } }` envelope (see `yana-server`'s
    /// `src/app/api/v1/ai/prompt/route.ts`) onto the reasons the reader can act on. Keyed on the
    /// error code rather than the status, since `YanaAPIClientError.server` carries only the
    /// envelope; the codes are the stable part of that contract anyway.
    static func failure(for error: YanaAPIClientError) -> AISummaryFailure {
        switch error {
        case .transport: return .unavailable(detail: "network")
        case .decoding: return .unavailable(detail: "response")
        case .unauthorized: return .unavailable(detail: "auth")
        case .server(let apiError):
            switch apiError.code {
            case "prompt_too_long": return .promptTooLong
            case "no_active_provider", "no_provider_configured": return .noProvider
            case "daily_limit_exceeded", "monthly_limit_exceeded": return .limitReached
            case "provider_error", "provider_unauthorized": return .providerError
            default: return .unavailable(detail: apiError.code)
            }
        }
    }
}

struct AppleIntelligenceSummaryProvider: AISummaryProvider {
    let generator: ArticleGenerating

    init(generator: ArticleGenerating = AppleIntelligenceClient()) {
        self.generator = generator
    }

    func summarize(content: String, title: String) async -> Result<String, AISummaryFailure> {
        guard generator.availability == .available else {
            return .failure(.unavailable(detail: "model unavailable"))
        }
        guard let summary = await AppleIntelligenceChunkedSummarizer.summarize(
            text: content, title: title, generator: generator
        ) else { return .failure(.unavailable(detail: "on-device")) }
        return .success(summary)
    }
}
