import AVFoundation
import Foundation
import NaturalLanguage
import SwiftSoup

/// Reads an article's text aloud with `AVSpeechSynthesizer`. Owned by the reader's pager so a single
/// synthesizer survives page swipes; the pager stops it whenever the visible article changes.
///
/// State is a simple three-way machine — `idle → speaking ⇄ paused` — surfaced to the pager via
/// `onStateChange` so it can keep the play/pause toolbar button in sync. The spoken voice is picked
/// to match the article's detected language (German articles read in a German voice, etc.), falling
/// back to the user's preferred locale.
@MainActor
final class ReaderSpeechController: NSObject, AVSpeechSynthesizerDelegate {

    enum State { case idle, speaking, paused }

    private(set) var state: State = .idle
    /// Invoked on the main actor whenever `state` changes so the host can refresh chrome.
    var onStateChange: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Begin reading `article` aloud from the start. No-op when there is nothing to speak.
    func speak(_ article: Article) {
        let text = Self.spokenText(for: article)
        guard !text.isEmpty else { return }
        // Replace any in-flight utterance so re-tapping play always restarts cleanly.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        activateAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        synthesizer.speak(utterance)
        setState(.speaking)
    }

    /// Pause while speaking, resume while paused. No effect when idle.
    func togglePauseResume() {
        switch state {
        case .speaking:
            synthesizer.pauseSpeaking(at: .word)
            setState(.paused)
        case .paused:
            synthesizer.continueSpeaking()
            setState(.speaking)
        case .idle:
            break
        }
    }

    /// Stop and reset to idle. Safe to call when already idle.
    func stop() {
        guard state != .idle else { return }
        synthesizer.stopSpeaking(at: .immediate)
        // `stopSpeaking` does not fire `didCancel` synchronously; settle the state here so callers
        // (e.g. a page swipe) see `idle` immediately.
        setState(.idle)
        deactivateAudioSession()
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.setState(.idle)
            self.deactivateAudioSession()
        }
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // `.playback`/`.spokenAudio` keeps reading audible even with the ringer silenced and pauses
        // (ducks) other audio while the article is read; deactivating on stop restores it.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Text + voice

    /// Plain, speakable text for an article: title, then AI summary (if any), then the body with all
    /// HTML stripped. Mirrors what the reader renders so the spoken text matches the page.
    static func spokenText(for article: Article) -> String {
        var parts: [String] = []
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append(title) }
        let summary = article.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { parts.append(summary) }
        if let body = try? SwiftSoup.parse(article.content).text(),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(body)
        }
        // A sentence break between sections gives the synthesizer a natural pause after the title.
        return parts.joined(separator: ".\n\n")
    }

    /// Pick a voice matching the text's dominant language, falling back to the user's preferred
    /// locale and finally the system default.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let code = recognizer.dominantLanguage?.rawValue, let voice = installedVoice(for: code) {
            return voice
        }
        if let preferred = Locale.preferredLanguages.first,
           let code = Locale(identifier: preferred).language.languageCode?.identifier,
           let voice = installedVoice(for: code) {
            return voice
        }
        return nil
    }

    /// First installed voice whose language matches `code` (e.g. "de" → "de-DE"), preferring an exact
    /// match before a language-prefix match.
    private static func installedVoice(for code: String) -> AVSpeechSynthesisVoice? {
        let code = code.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let match = voices.first { $0.language.lowercased() == code }
            ?? voices.first { $0.language.lowercased().hasPrefix(code + "-") }
        guard let match else { return nil }
        return AVSpeechSynthesisVoice(identifier: match.identifier)
    }
}
