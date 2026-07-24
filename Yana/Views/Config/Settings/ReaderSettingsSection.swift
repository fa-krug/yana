import AVFoundation
import SwiftUI

/// Reader preferences: text size, font, live preview, system-browser toggle, read-aloud voice.
struct ReaderSettingsSection: View {
    @State private var settings = AppSettings()

    var body: some View {
        Section {
            Picker(selection: Binding(
                get: { settings.articleTextSize },
                set: { settings.articleTextSize = $0 }
            )) {
                ForEach(ArticleTextSize.allCases) { size in
                    Text(size.displayName).tag(size)
                }
            } label: {
                Label(String(localized: "Text Size"), systemImage: "textformat.size")
                    .labelStyle(.tintedIcon(.indigo))
            }

            Picker(selection: Binding(
                get: { settings.articleFont },
                set: { settings.articleFont = $0 }
            )) {
                ForEach(ArticleFont.allCases) { font in
                    Text(font.displayName).tag(font)
                }
            } label: {
                Label(String(localized: "Font"), systemImage: "textformat")
                    .labelStyle(.tintedIcon(.indigo))
            }

            Text("The quick brown fox jumps over the lazy dog.")
                .font(.system(size: CGFloat(settings.articleTextSize.pointSize)))
                .fontDesign(settings.articleFont.design)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Text size preview"))

            Toggle(isOn: Binding(
                get: { settings.useSystemBrowser },
                set: { settings.useSystemBrowser = $0 }
            )) {
                Label(String(localized: "Use System Browser"), systemImage: "safari")
                    .labelStyle(.tintedIcon(.indigo))
            }

            Picker(selection: Binding(
                get: { settings.preferredVoiceIdentifier },
                set: { settings.preferredVoiceIdentifier = $0 }
            )) {
                Text("Automatic").tag(String?.none)
                ForEach(installedVoices, id: \.identifier) { voice in
                    Text(voiceLabel(voice)).tag(String?.some(voice.identifier))
                }
            } label: {
                Label(String(localized: "Read-Aloud Voice"), systemImage: "waveform")
                    .labelStyle(.tintedIcon(.indigo))
            }
        } header: {
            Text("Reader")
        } footer: {
            Text("Read-aloud uses the voice you choose here, or the most natural one installed for the article's language when set to Automatic, and keeps playing when the screen is locked or you switch apps. To add more natural voices, open Settings → Accessibility → Live Speech → Add Preferred Voice…")
        }
    }

    /// Installed speech voices, sorted by language then name, for the read-aloud voice picker.
    private var installedVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language
        }
    }

    /// Picker label for a voice: name plus its localized language, e.g. "Anna · German (Germany)".
    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(voice.name) · \(language)"
    }
}
