import SwiftUI

/// Focused values the Mac menu-bar commands read to act on the frontmost window's timeline + speech
/// controller. `MacRootView` publishes them via `.focusedValue(...)`.
extension FocusedValues {
    var timelineModel: TimelineModel? {
        get { self[TimelineModelKey.self] }
        set { self[TimelineModelKey.self] = newValue }
    }
    var readerSpeech: ReaderSpeechController? {
        get { self[ReaderSpeechKey.self] }
        set { self[ReaderSpeechKey.self] = newValue }
    }

    private struct TimelineModelKey: FocusedValueKey { typealias Value = TimelineModel }
    private struct ReaderSpeechKey: FocusedValueKey { typealias Value = ReaderSpeechController }
}

/// The Mac menu-bar commands. Mirrors the reader's actions with standard shortcuts and adds
/// keyboard article navigation (the sidebar list already accepts ↑/↓ when focused; these give an
/// explicit menu + shortcut that works regardless of focus).
struct YanaCommands: Commands {
    @FocusedValue(\.timelineModel) private var model
    @FocusedValue(\.readerSpeech) private var speech

    private var navDisabled: Bool { model == nil }

    var body: some Commands {
        // No multi-window on Mac, so drop the default New Window / New item menu slot.
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Article") {
            Button("Update all") { model?.triggerRefresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model == nil)

            Divider()

            Button("Next Article") { model?.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(navDisabled)
            Button("Previous Article") { model?.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(navDisabled)

            Divider()

            Button(starTitle) { if let a = model?.selectedArticle() { model?.toggleStar(a) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model?.selectedSummary == nil)

            Button(speechTitle) { toggleSpeech() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model?.selectedSummary == nil)
        }
    }

    private var starTitle: LocalizedStringKey {
        (model?.selectedSummary?.isStarred ?? false) ? "Unstar" : "Star"
    }

    private var speechTitle: LocalizedStringKey {
        speech?.state == .speaking ? "Pause Reading" : "Read Aloud"
    }

    private func toggleSpeech() {
        guard let speech else { return }
        if speech.state == .idle {
            if let article = model?.selectedArticle() { speech.speak(article) }
        } else {
            speech.togglePauseResume()
        }
    }
}
