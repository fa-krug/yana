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
            readerSection
            redditSection
            youtubeSection
            notificationsSection
            aiProviderSection
            aiKnobsSection
            librarySection
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadSecrets)
        .alert("Notifications Disabled", isPresented: $showNotificationDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable notifications for Yana in the Settings app to get alerts about new articles.")
        }
    }

    // MARK: Reader

    private var readerSection: some View {
        Section(String(localized: "Reader")) {
            Picker(selection: Binding(
                get: { settings.readerThemeName },
                set: { newValue in
                    settings.readerThemeName = newValue
                    ArticleThemesManager.shared.currentThemeName = newValue
                }
            )) {
                ForEach(ArticleThemesManager.shared.themeNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            } label: {
                Label(String(localized: "Theme"), systemImage: "paintbrush")
                    .labelStyle(.tintedIcon(.indigo))
            }

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

            Toggle(isOn: Binding(
                get: { settings.useSystemBrowser },
                set: { settings.useSystemBrowser = $0 }
            )) {
                Label(String(localized: "Use System Browser"), systemImage: "safari")
                    .labelStyle(.tintedIcon(.indigo))
            }
        }
    }

    // MARK: Sources

    private var redditSection: some View {
        Section("Reddit") {
            Toggle(isOn: $settings.redditEnabled) {
                Label("Enabled", systemImage: "bubble.left.and.bubble.right.fill")
                    .labelStyle(.tintedIcon(.orange))
            }
            SecureField("Client ID", text: $redditClientID)
                .onChange(of: redditClientID) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientID); redditStatus = .idle
                }
            SecureField("Client Secret", text: $redditClientSecret)
                .onChange(of: redditClientSecret) { _, v in
                    KeychainService.saveAPIKey(v, for: .redditClientSecret); redditStatus = .idle
                }
            TextField("User Agent", text: $settings.redditUserAgent)
                .autocorrectionDisabled()
            testControls(status: redditStatus,
                         disabled: redditClientID.isEmpty || redditClientSecret.isEmpty) {
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
                .onChange(of: youtubeKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .youtubeAPIKey); youtubeStatus = .idle
                }
            testControls(status: youtubeStatus, disabled: youtubeKey.isEmpty) {
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
                .onChange(of: openaiKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .openaiAPIKey); openaiStatus = .idle
                }
            TextField("API URL", text: $settings.openaiAPIURL).autocorrectionDisabled()
            Picker("Model", selection: $settings.openaiModel) {
                ForEach(AIProvider.openai.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: openaiStatus, disabled: openaiKey.isEmpty) {
                runTest({ openaiStatus = $0 }) {
                    await CredentialTester.ai(provider: .openai, apiKey: openaiKey,
                                              model: settings.openaiModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .anthropic:
            SecureField("API Key", text: $anthropicKey)
                .onChange(of: anthropicKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .anthropicAPIKey); anthropicStatus = .idle
                }
            Picker("Model", selection: $settings.anthropicModel) {
                ForEach(AIProvider.anthropic.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: anthropicStatus, disabled: anthropicKey.isEmpty) {
                runTest({ anthropicStatus = $0 }) {
                    await CredentialTester.ai(provider: .anthropic, apiKey: anthropicKey,
                                              model: settings.anthropicModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .gemini:
            SecureField("API Key", text: $geminiKey)
                .onChange(of: geminiKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .geminiAPIKey); geminiStatus = .idle
                }
            Picker("Model", selection: $settings.geminiModel) {
                ForEach(AIProvider.gemini.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: geminiStatus, disabled: geminiKey.isEmpty) {
                runTest({ geminiStatus = $0 }) {
                    await CredentialTester.ai(provider: .gemini, apiKey: geminiKey,
                                              model: settings.geminiModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .mistral:
            SecureField("API Key", text: $mistralKey)
                .onChange(of: mistralKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .mistralAPIKey); mistralStatus = .idle
                }
            Picker("Model", selection: $settings.mistralModel) {
                ForEach(AIProvider.mistral.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: mistralStatus, disabled: mistralKey.isEmpty) {
                runTest({ mistralStatus = $0 }) {
                    await CredentialTester.ai(provider: .mistral, apiKey: mistralKey,
                                              model: settings.mistralModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .qwen:
            SecureField("API Key", text: $qwenKey)
                .onChange(of: qwenKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .qwenAPIKey); qwenStatus = .idle
                }
            Picker("Model", selection: $settings.qwenModel) {
                ForEach(AIProvider.qwen.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: qwenStatus, disabled: qwenKey.isEmpty) {
                runTest({ qwenStatus = $0 }) {
                    await CredentialTester.ai(provider: .qwen, apiKey: qwenKey,
                                              model: settings.qwenModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .deepseek:
            SecureField("API Key", text: $deepseekKey)
                .onChange(of: deepseekKey) { _, v in
                    KeychainService.saveAPIKey(v, for: .deepseekAPIKey); deepseekStatus = .idle
                }
            Picker("Model", selection: $settings.deepseekModel) {
                ForEach(AIProvider.deepseek.models, id: \.self) { Text($0).tag($0) }
            }
            testControls(status: deepseekStatus, disabled: deepseekKey.isEmpty) {
                runTest({ deepseekStatus = $0 }) {
                    await CredentialTester.ai(provider: .deepseek, apiKey: deepseekKey,
                                              model: settings.deepseekModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .appleIntelligence:
            LabeledContent("Status", value: appleIntelligenceStatus)
            testControls(status: appleStatus, disabled: false) {
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
            Stepper("Max Prompt Length: \(settings.aiMaxPromptLength)", value: $settings.aiMaxPromptLength, in: 100...4000, step: 100)
            Stepper("Daily Limit: \(settings.aiDefaultDailyLimit)", value: $settings.aiDefaultDailyLimit, in: 0...5000, step: 50)
            Stepper("Monthly Limit: \(settings.aiDefaultMonthlyLimit)", value: $settings.aiDefaultMonthlyLimit, in: 0...50000, step: 100)
            Stepper("Request Timeout: \(settings.aiRequestTimeout)s", value: $settings.aiRequestTimeout, in: 10...600, step: 10)
            Stepper("Max Retries: \(settings.aiMaxRetries)", value: $settings.aiMaxRetries, in: 0...10)
            Stepper("Retry Delay: \(settings.aiRetryDelay)s", value: $settings.aiRetryDelay, in: 0...60)
            Stepper("Request Delay: \(settings.aiRequestDelay)s", value: $settings.aiRequestDelay, in: 0...60)
        }
    }

    private var librarySection: some View {
        Section("Library") {
            Stepper(value: $settings.retentionDays, in: 1...365) {
                Label("Keep Articles: \(settings.retentionDays) days", systemImage: "calendar")
                    .labelStyle(.tintedIcon(.blue))
            }
            Stepper(value: $settings.backgroundInterval, in: 300...21600, step: 300) {
                Label("Background Refresh: \(Int(settings.backgroundInterval / 60)) min",
                      systemImage: "arrow.clockwise")
                    .labelStyle(.tintedIcon(.blue))
            }
        }
    }

    /// A "Test" button plus an inline status row, reused by every credential section.
    @ViewBuilder
    private func testControls(status: TestStatus, disabled: Bool, action: @escaping () -> Void) -> some View {
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
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
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
    }
}
