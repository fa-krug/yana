import Foundation
import NaturalLanguage

/// Which language an AI summary should be written in.
///
/// A model writes in the language of its instructions unless told otherwise, and every instruction
/// string on both summarize paths is English -- so a German article got an English summary. This
/// resolves a target language from the article text itself (the same "detect the dominant language
/// of the first couple of sentences" rule `ReaderSpeechController` already uses to pick a voice)
/// and renders it as an explicit instruction sentence.
///
/// Naming the language beats "answer in the same language as the article": a model follows a
/// concrete directive far more reliably than one it has to infer from the input, and the small
/// on-device model especially so.
///
/// **Both paths need this, not just the on-device one.** `ServerAISummaryProvider` used to send no
/// directive at all, on the assumption that a hosted model mirrors the language of the text it is
/// given. It does not: the surrounding instruction ("Summarize the following article...") is
/// English, and that is what the model answers in, so a German article came back summarized in
/// English there too.
enum SummaryLanguage {
    /// Language detection needs a couple of sentences, not the whole article.
    static let detectionPrefix = 2000

    /// An instruction sentence naming the language to write in, or `nil` when no supported language
    /// can be resolved (leaving the model's own default in place).
    ///
    /// Candidates, in order: the article's dominant language, then the user's preferred language.
    /// A candidate the model does not support is skipped, since asking for output in a language the
    /// model cannot write is worse than an English summary. `supported: nil` means "unrestricted",
    /// which is the server path: the app cannot enumerate a hosted provider's languages, and the
    /// hosted models the server fronts are multilingual anyway, so filtering there would only ever
    /// drop a language the model can in fact write.
    static func directive(text: String,
                          supported: Set<Locale.Language>?,
                          preferred: [String] = Locale.preferredLanguages) -> String? {
        guard let name = languageName(text: text, supported: supported, preferred: preferred) else { return nil }
        return "Write the summary in \(name), regardless of the language of these instructions."
    }

    /// The English name of the resolved language ("German", "Chinese (Simplified)"), or `nil`.
    static func languageName(text: String,
                             supported: Set<Locale.Language>?,
                             preferred: [String] = Locale.preferredLanguages) -> String? {
        let candidates = [detect(text)] + preferred.map { Locale.Language(identifier: $0) }
        for candidate in candidates.compactMap({ $0 }) where isSupported(candidate, in: supported) {
            if let name = englishName(for: candidate) { return name }
        }
        return nil
    }

    /// Dominant language of the article text, or `nil` when detection is inconclusive.
    static func detect(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(detectionPrefix)))
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        return Locale.Language(identifier: code)
    }

    /// Match on language code alone (plus script when both sides declare one): the model reports
    /// support per locale (`de-DE`, `zh-CN`), while detection yields a bare language or a
    /// language+script (`de`, `zh-Hans`), so comparing whole identifiers never matches.
    static func isSupported(_ language: Locale.Language, in supported: Set<Locale.Language>?) -> Bool {
        guard let code = language.languageCode?.identifier else { return false }
        guard let supported else { return true }   // unrestricted: see `directive`.
        return supported.contains { candidate in
            guard candidate.languageCode?.identifier == code else { return false }
            guard let script = language.script, let candidateScript = candidate.script else { return true }
            return script == candidateScript
        }
    }

    /// Always English, whatever the device language: this feeds an English instruction string, so
    /// "German" belongs there rather than the user-facing "Deutsch".
    private static func englishName(for language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier else { return nil }
        let identifier = language.script.map { "\(code)-\($0.identifier)" } ?? code
        let english = Locale(identifier: "en_US")
        return english.localizedString(forIdentifier: identifier)
            ?? english.localizedString(forLanguageCode: code)
    }
}
