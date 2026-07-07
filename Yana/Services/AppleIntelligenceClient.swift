import Foundation
import FoundationModels

/// App-owned availability so the rest of the app never imports the framework's reason types
/// and tests can inject a value.
enum AppleIntelligenceAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible   // hardware can't run Apple Intelligence
    case notEnabled          // Apple Intelligence turned off in Settings
    case modelNotReady       // downloading / not yet ready
}

/// Guided-generation output shape. Type-safe replacement for JSON parsing on the Apple path.
@Generable
struct ProcessedArticle {
    @Guide(description: "The processed article title")
    var title: String
    @Guide(description: "The processed article body as valid HTML, preserving the input structure")
    var content: String
}

/// Guided-generation output shape for the summary pass. A distinct type whose `@Guide`
/// steers the model toward a concise summary — reusing `ProcessedArticle` here made the
/// model reproduce the full article body (its `content` guide says "preserve the input
/// structure"), so summaries came back as the article verbatim.
@Generable
struct GeneratedSummary {
    @Guide(description: "A concise summary of the article in plain text — a few sentences at most, not the full article")
    var summary: String
}

/// Abstraction over on-device generation so `AppleIntelligenceProcessor` is testable with a fake.
protocol ArticleGenerating: Sendable {
    var availability: AppleIntelligenceAvailability { get }
    /// Estimated token count, for chunk budgeting.
    func tokenCount(_ text: String) -> Int
    /// One guided-generation call for the body-rewrite pass. Throws on generation failure.
    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle
    /// One guided-generation call for the summary pass, returning plain-text summary. Throws on failure.
    func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String
}

/// Concrete `ArticleGenerating` backed by the on-device system language model.
struct AppleIntelligenceClient: ArticleGenerating {
    var availability: AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .modelNotReady
        }
    }

    /// Heuristic ~3.5 chars/token; overestimates tokens slightly so chunks stay within budget.
    /// (The model's exact token API is iOS 26.4+; the heuristic keeps us building on 26.0.)
    func tokenCount(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 3.5).rounded(.up)))
    }

    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, generating: ProcessedArticle.self, options: options)
        return response.content
    }

    func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, generating: GeneratedSummary.self, options: options)
        return response.content.summary
    }

    /// One free-form text generation (no guided schema), used by the selector suggester which
    /// parses the model's JSON reply itself. Throws on generation failure.
    func generateText(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }
}
