import Foundation
import Testing
@testable import Yana

/// The regression these pin: nothing in the on-device summarize path ever named an output language,
/// so the model answered in the language of its (always English) instructions -- a German article
/// got an English summary.
@Suite("SummaryLanguage")
struct SummaryLanguageTests {
    let german = """
    Der Bundestag hat am Mittwoch über den Haushalt beraten. Die Abgeordneten diskutierten \
    mehrere Stunden über die geplanten Ausgaben für Bildung und Verkehr. Am Ende wurde der \
    Entwurf mit knapper Mehrheit an die Ausschüsse zurückverwiesen.
    """
    let english = """
    The committee met on Wednesday to review the annual budget. Members spent several hours \
    debating planned spending on education and transport before sending the draft back for \
    further review.
    """
    let supported: Set<Locale.Language> = [
        Locale.Language(identifier: "en-US"),
        Locale.Language(identifier: "de-DE"),
        Locale.Language(identifier: "zh-CN")
    ]

    @Test func germanArticleAsksForAGermanSummary() {
        let directive = SummaryLanguage.directive(text: german, supported: supported, preferred: ["en-US"])
        #expect(directive?.contains("German") == true)
    }

    @Test func englishArticleAsksForAnEnglishSummary() {
        let directive = SummaryLanguage.directive(text: english, supported: supported, preferred: ["de-DE"])
        #expect(directive?.contains("English") == true)
    }

    /// Asking for output in a language the model cannot write is worse than its own default.
    @Test func unsupportedDetectedLanguageFallsBackToPreferred() {
        let directive = SummaryLanguage.directive(text: german,
                                                 supported: [Locale.Language(identifier: "en-US")],
                                                 preferred: ["en-US"])
        #expect(directive?.contains("English") == true)
    }

    @Test func noSupportedLanguageYieldsNoDirective() {
        #expect(SummaryLanguage.directive(text: german, supported: [], preferred: ["en-US"]) == nil)
    }

    /// Detection yields a bare language or language+script; the model reports support per locale.
    @Test func supportMatchesOnLanguageCodeNotWholeIdentifier() {
        #expect(SummaryLanguage.isSupported(Locale.Language(identifier: "de"), in: supported))
        #expect(SummaryLanguage.isSupported(Locale.Language(identifier: "fr"), in: supported) == false)
    }

    @Test func scriptIsHonouredWhenBothSidesDeclareOne() {
        let hans = Locale.Language(identifier: "zh-Hans")
        #expect(SummaryLanguage.isSupported(hans, in: [Locale.Language(identifier: "zh-Hant")]) == false)
        #expect(SummaryLanguage.isSupported(hans, in: [Locale.Language(identifier: "zh-Hans-CN")]))
    }
}

/// The directive has to reach BOTH generation passes: a reduce step without it would translate the
/// per-chunk summaries back into the instruction language.
@Suite("SummaryLanguage in the chunked summarizer")
struct SummarizerLanguageDirectiveTests {
    final class RecordingGenerator: ArticleGenerating, @unchecked Sendable {
        let availability: AppleIntelligenceAvailability = .available
        let supportedLanguages: Set<Locale.Language> = [Locale.Language(identifier: "en-US"),
                                                        Locale.Language(identifier: "de-DE")]
        var instructions: [String] = []
        func tokenCount(_ text: String) -> Int { text.count }
        func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
            throw NSError(domain: "test", code: 1)
        }
        func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
            self.instructions.append(instructions)
            return "Zusammenfassung"
        }
    }

    @Test func germanArticleInstructsBothPassesInGerman() async {
        let paragraph = """
        Der Bundestag hat am Mittwoch über den Haushalt beraten und die Abgeordneten haben \
        mehrere Stunden über die geplanten Ausgaben für Bildung und Verkehr diskutiert.
        """
        // Two paragraphs well past contentBudgetTokens (1 token/char here) force a reduce pass.
        let long = String(repeating: paragraph + " ", count: 20)
        let gen = RecordingGenerator()
        _ = await AppleIntelligenceChunkedSummarizer.summarize(text: long + "\n\n" + long,
                                                              title: "Haushalt",
                                                              generator: gen)
        #expect(gen.instructions.count >= 3)   // ≥2 map passes + 1 reduce
        #expect(gen.instructions.allSatisfy { $0.contains("German") })
    }
}
