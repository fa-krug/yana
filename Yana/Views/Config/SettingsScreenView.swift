import SwiftUI

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
                .onChange(of: redditClientID) { _, v in KeychainService.saveAPIKey(v, for: .redditClientID) }
            SecureField("Client Secret", text: $redditClientSecret)
                .onChange(of: redditClientSecret) { _, v in KeychainService.saveAPIKey(v, for: .redditClientSecret) }
            TextField("User Agent", text: $settings.redditUserAgent)
                .autocorrectionDisabled()
        }
    }

    private var youtubeSection: some View {
        Section("YouTube") {
            Toggle(isOn: $settings.youtubeEnabled) {
                Label("Enabled", systemImage: "play.rectangle.fill")
                    .labelStyle(.tintedIcon(.red))
            }
            SecureField("API Key", text: $youtubeKey)
                .onChange(of: youtubeKey) { _, v in KeychainService.saveAPIKey(v, for: .youtubeAPIKey) }
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

            DisclosureGroup("OpenAI") {
                SecureField("API Key", text: $openaiKey)
                    .onChange(of: openaiKey) { _, v in KeychainService.saveAPIKey(v, for: .openaiAPIKey) }
                TextField("API URL", text: $settings.openaiAPIURL).autocorrectionDisabled()
                Picker("Model", selection: $settings.openaiModel) {
                    ForEach(AIProvider.openai.models, id: \.self) { Text($0).tag($0) }
                }
            }
            DisclosureGroup("Anthropic") {
                SecureField("API Key", text: $anthropicKey)
                    .onChange(of: anthropicKey) { _, v in KeychainService.saveAPIKey(v, for: .anthropicAPIKey) }
                Picker("Model", selection: $settings.anthropicModel) {
                    ForEach(AIProvider.anthropic.models, id: \.self) { Text($0).tag($0) }
                }
            }
            DisclosureGroup("Gemini") {
                SecureField("API Key", text: $geminiKey)
                    .onChange(of: geminiKey) { _, v in KeychainService.saveAPIKey(v, for: .geminiAPIKey) }
                Picker("Model", selection: $settings.geminiModel) {
                    ForEach(AIProvider.gemini.models, id: \.self) { Text($0).tag($0) }
                }
            }
            if settings.activeAIProvider == .appleIntelligence {
                LabeledContent("Status", value: appleIntelligenceStatus)
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

    private func loadSecrets() {
        redditClientID = KeychainService.loadAPIKey(for: .redditClientID) ?? ""
        redditClientSecret = KeychainService.loadAPIKey(for: .redditClientSecret) ?? ""
        youtubeKey = KeychainService.loadAPIKey(for: .youtubeAPIKey) ?? ""
        openaiKey = KeychainService.loadAPIKey(for: .openaiAPIKey) ?? ""
        anthropicKey = KeychainService.loadAPIKey(for: .anthropicAPIKey) ?? ""
        geminiKey = KeychainService.loadAPIKey(for: .geminiAPIKey) ?? ""
    }
}
