import AVFoundation
import SwiftUI

/// Per-section credential-test state shown in Settings.
enum TestStatus: Equatable {
    case idle
    case testing
    case valid
    case invalid(String)   // localized message
}

/// Full-parity settings: sources (Reddit/YouTube), AI providers + knobs, library prefs.
/// Secrets are read from / written to the Keychain via local @State; non-secret prefs go to
/// `AppSettings` (UserDefaults).
struct SettingsScreenView: View {
    /// Called after the onboarding flag is reset, so the host can re-present the welcome screen
    /// once this settings sheet has dismissed.
    var onRestartOnboarding: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings()
    @State private var showNotificationDeniedAlert = false

    // Keychain-backed secrets (loaded onAppear, written on change).
    @State private var redditClientID = ""
    @State private var redditClientSecret = ""
    @State private var youtubeKey = ""
    @State private var openaiKey = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var mistralKey = ""
    @State private var qwenKey = ""
    @State private var deepseekKey = ""

    @State private var redditStatus: TestStatus = .idle
    @State private var youtubeStatus: TestStatus = .idle
    @State private var openaiStatus: TestStatus = .idle
    @State private var anthropicStatus: TestStatus = .idle
    @State private var geminiStatus: TestStatus = .idle
    @State private var mistralStatus: TestStatus = .idle
    @State private var qwenStatus: TestStatus = .idle
    @State private var deepseekStatus: TestStatus = .idle
    @State private var appleStatus: TestStatus = .idle

    var body: some View {
        Form {
            organizeSection
            readerSection
            redditSection
            youtubeSection
            notificationsSection
            aiProviderSection
            aiKnobsSection
            librarySection
            aboutSection
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
        }
        .onAppear(perform: loadSecrets)
        .alert("Notifications Disabled", isPresented: $showNotificationDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable notifications for Yana in the Settings app to get alerts about new articles.")
        }
    }

    // MARK: Organize

    private var organizeSection: some View {
        Section {
            NavigationLink {
                FeedsView()
            } label: {
                Label("Feeds", systemImage: "list.bullet.rectangle")
                    .labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.feeds")
            NavigationLink {
                TagsView()
            } label: {
                Label("Tags", systemImage: "tag")
                    .labelStyle(.tintedIcon(.pink))
            }
        } footer: {
            Text("Manage your feeds and the tags applied to articles.")
        }
    }

    // MARK: Reader

    private var readerSection: some View {
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

    // MARK: Sources

    private var redditSection: some View {
        Section("Reddit") {
            Toggle(isOn: $settings.redditEnabled) {
                Label("Enabled", systemImage: "bubble.left.and.bubble.right.fill")
                    .labelStyle(.tintedIcon(.orange))
            }
            SecureField("Client ID", text: $redditClientID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(redditStatus == .testing)
                .onChange(of: redditClientID) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientID); redditStatus = .idle
                }
            SecureField("Client Secret", text: $redditClientSecret)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(redditStatus == .testing)
                .onChange(of: redditClientSecret) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientSecret); redditStatus = .idle
                }
            TextField("User Agent", text: $settings.redditUserAgent)
                .autocorrectionDisabled()
            testControls(status: redditStatus,
                         disabled: redditClientID.isEmpty || redditClientSecret.isEmpty,
                         onClear: { redditStatus = .idle }) {
                runTest({ redditStatus = $0 }) {
                    await CredentialTester.reddit(clientID: redditClientID,
                                                  clientSecret: redditClientSecret,
                                                  userAgent: settings.redditUserAgent)
                }
            }
        }
    }

    private var youtubeSection: some View {
        Section("YouTube") {
            Toggle(isOn: $settings.youtubeEnabled) {
                Label("Enabled", systemImage: "play.rectangle.fill")
                    .labelStyle(.tintedIcon(.red))
            }
            SecureField("API Key", text: $youtubeKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(youtubeStatus == .testing)
                .onChange(of: youtubeKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .youtubeAPIKey); youtubeStatus = .idle
                }
            testControls(status: youtubeStatus, disabled: youtubeKey.isEmpty,
                         onClear: { youtubeStatus = .idle }) {
                runTest({ youtubeStatus = $0 }) {
                    await CredentialTester.youtube(apiKey: youtubeKey)
                }
            }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle(isOn: Binding(
                get: { settings.notificationsEnabled },
                set: { newValue in
                    if newValue {
                        Task {
                            let granted = await NotificationService().requestAuthorization()
                            settings.notificationsEnabled = granted
                            if !granted { showNotificationDeniedAlert = true }
                        }
                    } else {
                        settings.notificationsEnabled = false
                    }
                }
            )) {
                Label("Notify about new articles", systemImage: "bell.badge.fill")
                    .labelStyle(.tintedIcon(.red))
            }
        }
    }

    // MARK: AI providers

    private var aiProviderSection: some View {
        Section("AI Provider") {
            Picker(selection: $settings.activeAIProvider) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            } label: {
                Label("Active Provider", systemImage: "sparkles")
                    .labelStyle(.tintedIcon(.purple))
            }
            .accessibilityIdentifier("settings.aiSection")

            providerConfig
        }
    }

    /// Detailed config for the currently-selected provider only (mirrors AggregatorOptionsForm's
    /// switch-on-type). `.none` shows nothing; keys for other providers stay in the Keychain.
    @ViewBuilder
    private var providerConfig: some View {
        switch settings.activeAIProvider {
        case .none:
            EmptyView()
        case .openai:
            SecureField("API Key", text: $openaiKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(openaiStatus == .testing)
                .onChange(of: openaiKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .openaiAPIKey); openaiStatus = .idle
                }
            TextField("API URL", text: $settings.openaiAPIURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(openaiStatus == .testing)
            Picker("Model", selection: $settings.openaiModel) {
                ForEach(AIProvider.openai.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: openaiStatus, disabled: openaiKey.isEmpty,
                         onClear: { openaiStatus = .idle }) {
                runTest({ openaiStatus = $0 }) {
                    await CredentialTester.ai(provider: .openai, apiKey: openaiKey,
                                              model: settings.openaiModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .anthropic:
            SecureField("API Key", text: $anthropicKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(anthropicStatus == .testing)
                .onChange(of: anthropicKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .anthropicAPIKey); anthropicStatus = .idle
                }
            Picker("Model", selection: $settings.anthropicModel) {
                ForEach(AIProvider.anthropic.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: anthropicStatus, disabled: anthropicKey.isEmpty,
                         onClear: { anthropicStatus = .idle }) {
                runTest({ anthropicStatus = $0 }) {
                    await CredentialTester.ai(provider: .anthropic, apiKey: anthropicKey,
                                              model: settings.anthropicModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .gemini:
            SecureField("API Key", text: $geminiKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(geminiStatus == .testing)
                .onChange(of: geminiKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .geminiAPIKey); geminiStatus = .idle
                }
            Picker("Model", selection: $settings.geminiModel) {
                ForEach(AIProvider.gemini.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: geminiStatus, disabled: geminiKey.isEmpty,
                         onClear: { geminiStatus = .idle }) {
                runTest({ geminiStatus = $0 }) {
                    await CredentialTester.ai(provider: .gemini, apiKey: geminiKey,
                                              model: settings.geminiModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .mistral:
            SecureField("API Key", text: $mistralKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(mistralStatus == .testing)
                .onChange(of: mistralKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .mistralAPIKey); mistralStatus = .idle
                }
            Picker("Model", selection: $settings.mistralModel) {
                ForEach(AIProvider.mistral.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: mistralStatus, disabled: mistralKey.isEmpty,
                         onClear: { mistralStatus = .idle }) {
                runTest({ mistralStatus = $0 }) {
                    await CredentialTester.ai(provider: .mistral, apiKey: mistralKey,
                                              model: settings.mistralModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .qwen:
            SecureField("API Key", text: $qwenKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(qwenStatus == .testing)
                .onChange(of: qwenKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .qwenAPIKey); qwenStatus = .idle
                }
            Picker("Model", selection: $settings.qwenModel) {
                ForEach(AIProvider.qwen.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: qwenStatus, disabled: qwenKey.isEmpty,
                         onClear: { qwenStatus = .idle }) {
                runTest({ qwenStatus = $0 }) {
                    await CredentialTester.ai(provider: .qwen, apiKey: qwenKey,
                                              model: settings.qwenModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .deepseek:
            SecureField("API Key", text: $deepseekKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(deepseekStatus == .testing)
                .onChange(of: deepseekKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .deepseekAPIKey); deepseekStatus = .idle
                }
            Picker("Model", selection: $settings.deepseekModel) {
                ForEach(AIProvider.deepseek.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: deepseekStatus, disabled: deepseekKey.isEmpty,
                         onClear: { deepseekStatus = .idle }) {
                runTest({ deepseekStatus = $0 }) {
                    await CredentialTester.ai(provider: .deepseek, apiKey: deepseekKey,
                                              model: settings.deepseekModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .appleIntelligence:
            LabeledContent("Status", value: appleIntelligenceStatus)
            testControls(status: appleStatus, disabled: false,
                         onClear: { appleStatus = .idle }) {
                let available = AppleIntelligenceClient().availability == .available
                appleStatus = available ? .valid : .invalid(appleIntelligenceStatus)
            }
        }
    }

    private var appleIntelligenceStatus: String {
        switch AppleIntelligenceClient().availability {
        case .available:
            return String(localized: "Available")
        case .deviceNotEligible:
            return String(localized: "Not available on this device")
        case .notEnabled:
            return String(localized: "Turn on Apple Intelligence in Settings")
        case .modelNotReady:
            return String(localized: "Model downloading…")
        }
    }

    private var aiKnobsSection: some View {
        Section("AI Tuning") {
            HStack {
                Text("Temperature")
                Slider(value: $settings.aiTemperature, in: 0...1, step: 0.05)
                Text(settings.aiTemperature, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Stepper("Max Tokens: \(settings.aiMaxTokens)", value: $settings.aiMaxTokens, in: 256...8000, step: 256)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            DisclosureGroup("Advanced") {
                Stepper("Max Prompt Length: \(settings.aiMaxPromptLength)", value: $settings.aiMaxPromptLength, in: 100...4000, step: 100)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Daily Limit: \(settings.aiDefaultDailyLimit)", value: $settings.aiDefaultDailyLimit, in: 0...5000, step: 50)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Monthly Limit: \(settings.aiDefaultMonthlyLimit)", value: $settings.aiDefaultMonthlyLimit, in: 0...50000, step: 100)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Request Timeout: \(settings.aiRequestTimeout)s", value: $settings.aiRequestTimeout, in: 10...600, step: 10)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Max Retries: \(settings.aiMaxRetries)", value: $settings.aiMaxRetries, in: 0...10)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Retry Delay: \(settings.aiRetryDelay)s", value: $settings.aiRetryDelay, in: 0...60)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Request Delay: \(settings.aiRequestDelay)s", value: $settings.aiRequestDelay, in: 0...60)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var librarySection: some View {
        Section("Library") {
            Stepper(value: $settings.retentionDays, in: 1...365) {
                Label("Keep Articles: \(settings.retentionDays) days", systemImage: "calendar")
                    .labelStyle(.tintedIcon(.blue))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Stepper(value: $settings.backgroundInterval, in: 300...21600, step: 300) {
                Label("Background Refresh: \(Int(settings.backgroundInterval / 60)) min",
                      systemImage: "arrow.clockwise")
                    .labelStyle(.tintedIcon(.blue))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            Link(destination: URL(string: "https://github.com/fa-krug/yana")!) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    .labelStyle(.tintedIcon(.gray))
            }
            Link(destination: URL(string: "https://github.com/fa-krug/yana/issues")!) {
                Label("Suggest a Source or Report an Issue", systemImage: "exclamationmark.bubble")
                    .labelStyle(.tintedIcon(.green))
            }
            Link(destination: URL(string: "https://netnewswire.com")!) {
                Label("Reader View Inspired by NetNewsWire", systemImage: "heart")
                    .labelStyle(.tintedIcon(.pink))
            }
            Button {
                settings.hasCompletedOnboarding = false
                onRestartOnboarding()
                dismiss()
            } label: {
                Label("Show Welcome Screen Again", systemImage: "sparkles")
                    .labelStyle(.tintedIcon(.orange))
            }
            .accessibilityIdentifier("settings.showWelcome")
        } header: {
            Text("About")
        } footer: {
            Text("Yana is free and open source. The list of built-in sources grows from what people ask for, so suggest one on the issue board. Thanks to the NetNewsWire team, whose clean reader view shaped how articles look here.")
        }
    }

    /// A "Test" button plus an inline status row, reused by every credential section.
    @ViewBuilder
    private func testControls(status: TestStatus, disabled: Bool,
                             onClear: @escaping () -> Void,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("Test")
                if status == .testing {
                    Spacer()
                    Text("Testing…")
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
            }
        }
        .disabled(disabled || status == .testing)

        switch status {
        case .idle, .testing:
            EmptyView()
        case .valid:
            Label("Credentials valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            HStack {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button("Clear", action: onClear)
                    .buttonStyle(.borderless)
            }
        }
    }

    /// Run an async credential test, threading its status through `setter`.
    private func runTest(_ setter: @escaping (TestStatus) -> Void,
                         _ op: @escaping () async -> CredentialTestError?) {
        setter(.testing)
        Task {
            let error = await op()
            setter(error.map { .invalid($0.localizedMessage) } ?? .valid)
        }
    }

    private func loadSecrets() {
        redditClientID = KeychainService.loadAPIKey(for: .redditClientID) ?? ""
        redditClientSecret = KeychainService.loadAPIKey(for: .redditClientSecret) ?? ""
        youtubeKey = KeychainService.loadAPIKey(for: .youtubeAPIKey) ?? ""
        openaiKey = KeychainService.loadAPIKey(for: .openaiAPIKey) ?? ""
        anthropicKey = KeychainService.loadAPIKey(for: .anthropicAPIKey) ?? ""
        geminiKey = KeychainService.loadAPIKey(for: .geminiAPIKey) ?? ""
        mistralKey = KeychainService.loadAPIKey(for: .mistralAPIKey) ?? ""
        qwenKey = KeychainService.loadAPIKey(for: .qwenAPIKey) ?? ""
        deepseekKey = KeychainService.loadAPIKey(for: .deepseekAPIKey) ?? ""

        // Under the screenshot launch arg, ensure a provider is selected so the API-key /
        // model / Test fields are visible. Does not affect normal app behavior.
        if ProcessInfo.processInfo.arguments.contains("-UITEST_SCREENSHOTS"),
           settings.activeAIProvider == .none {
            settings.activeAIProvider = .openai
        }
    }
}
