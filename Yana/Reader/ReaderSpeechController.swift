import AVFoundation
import Foundation
import MediaPlayer
import NaturalLanguage

/// Reads an article's text aloud with `AVSpeechSynthesizer`. Owned by the reader's pager so a single
/// synthesizer survives page swipes; the pager stops it whenever the visible article changes.
///
/// State is a simple three-way machine — `idle → speaking ⇄ paused` — surfaced to the pager via
/// `onStateChange` so it can keep the play/pause toolbar button in sync. The spoken voice is picked
/// to match the article's detected language (German articles read in a German voice, etc.), preferring
/// the most natural (Premium → Enhanced → default) voice the user has installed for that language.
///
/// Playback continues while the app is backgrounded or the screen is locked: the `audio`
/// `UIBackgroundMode` keeps the synthesizer running, and a `MPNowPlayingInfoCenter` /
/// `MPRemoteCommandCenter` registration surfaces the article on the lock screen with working
/// play/pause/stop controls.
@MainActor
final class ReaderSpeechController: NSObject, AVSpeechSynthesizerDelegate {

    enum State { case idle, speaking, paused }

    private(set) var state: State = .idle
    /// Invoked on the main actor whenever `state` changes so the host can refresh chrome.
    var onStateChange: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    /// Title of the article currently being read, kept for the lock-screen Now Playing info.
    private var nowPlayingTitle = ""
    private var nowPlayingArtist = ""

    override init() {
        super.init()
        synthesizer.delegate = self
        configureRemoteCommands()
    }

    /// Begin reading `article` aloud from the start. No-op when there is nothing to speak.
    func speak(_ article: Article) {
        let text = Self.spokenText(for: article)
        guard !text.isEmpty else { return }
        // Replace any in-flight utterance so re-tapping play always restarts cleanly.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        nowPlayingTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        nowPlayingArtist = article.author.trimmingCharacters(in: .whitespacesAndNewlines)
        activateAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        synthesizer.speak(utterance)
        setState(.speaking)
        updateNowPlaying(playing: true)
    }

    /// Pause while speaking, resume while paused. No effect when idle.
    func togglePauseResume() {
        switch state {
        case .speaking:
            synthesizer.pauseSpeaking(at: .word)
            setState(.paused)
            updateNowPlaying(playing: false)
        case .paused:
            synthesizer.continueSpeaking()
            setState(.speaking)
            updateNowPlaying(playing: true)
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
        clearNowPlaying()
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
            self.clearNowPlaying()
            self.deactivateAudioSession()
        }
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // `.playback`/`.spokenAudio` keeps reading audible even with the ringer silenced and lets the
        // synthesizer keep running while the app is backgrounded or the screen is locked (paired with
        // the `audio` UIBackgroundMode). It also makes Yana the system "Now Playing" app, so the
        // lock-screen transport controls drive this controller.
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Lock-screen Now Playing

    /// Wire the lock-screen / Control Center transport buttons to this controller once. Targets are
    /// no-ops while idle, so they can stay registered for the controller's lifetime.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .paused else { return .commandFailed }
                self.togglePauseResume()
                return .success
            }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .speaking else { return .commandFailed }
                self.togglePauseResume()
                return .success
            }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state != .idle else { return .commandFailed }
                self.togglePauseResume()
                return .success
            }
        }
        center.stopCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state != .idle else { return .commandFailed }
                self.stop()
                return .success
            }
        }
    }

    private func updateNowPlaying(playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if !nowPlayingArtist.isEmpty { info[MPMediaItemPropertyArtist] = nowPlayingArtist }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }

    private func clearNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    // MARK: - Text + voice

    /// Plain, speakable text for an article: title, then AI summary (if any), then the body text.
    /// Reads the article's `plainText` (its blocks flattened to visible text), so the spoken text
    /// matches what the reader renders. URLs are stripped first — a synthesizer reads a link out as
    /// an unintelligible run of characters ("h-t-t-p-colon-slash-slash…"), so we drop them rather
    /// than read them aloud.
    static func spokenText(for article: Article) -> String {
        var parts: [String] = []
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append(title) }
        let summary = article.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { parts.append(summary) }
        let body = article.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        // A sentence break between sections gives the synthesizer a natural pause after the title.
        return strippingURLs(from: parts.joined(separator: ".\n\n"))
    }

    /// Remove URLs (and bare web addresses like `www.example.com`) from text destined for the
    /// synthesizer so they aren't read aloud. Uses `NSDataDetector` so it catches the same links the
    /// system recognizes; the gaps left behind are collapsed so no stray double spaces remain.
    static func strippingURLs(from text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let full = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }
        var result = text
        // Remove from the end backwards so earlier ranges stay valid as we mutate.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.removeSubrange(range)
        }
        return collapseWhitespace(result)
    }

    /// Collapse the runs of spaces/blank lines left where URLs were removed: horizontal whitespace
    /// folds to a single space and stray spaces around line breaks are trimmed, so the synthesizer
    /// doesn't pause awkwardly in the gaps.
    private static func collapseWhitespace(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pick a voice for `text`. A voice the user explicitly chose in Settings wins (when it is still
    /// installed); otherwise match the text's dominant language, falling back to the user's preferred
    /// locale and finally the system default.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        if let identifier = AppSettings().preferredVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
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

    /// The most natural installed voice whose language matches `code` (e.g. "de" → "de-DE").
    /// Among the matches it prefers higher synthesis quality (Premium → Enhanced → default) and,
    /// at equal quality, an exact language match over a language-prefix match — so the reader uses
    /// a downloaded natural voice when one is available instead of the robotic compact default.
    private static func installedVoice(for code: String) -> AVSpeechSynthesisVoice? {
        let code = code.lowercased()
        let matches = AVSpeechSynthesisVoice.speechVoices().filter {
            let lang = $0.language.lowercased()
            return lang == code || lang.hasPrefix(code + "-")
        }
        guard let best = matches.max(by: { score($0, code: code) < score($1, code: code) }) else {
            return nil
        }
        return AVSpeechSynthesisVoice(identifier: best.identifier)
    }

    /// Ranking key for `installedVoice`: quality dominates, exact-language match breaks ties.
    private static func score(_ voice: AVSpeechSynthesisVoice, code: String) -> Int {
        let qualityRank: Int
        switch voice.quality {
        case .premium: qualityRank = 2
        case .enhanced: qualityRank = 1
        default: qualityRank = 0
        }
        let exactMatch = voice.language.lowercased() == code ? 1 : 0
        return qualityRank * 2 + exactMatch
    }
}
