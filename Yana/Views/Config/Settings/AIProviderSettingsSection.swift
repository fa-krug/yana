import SwiftUI

/// AI provider selection plus the detailed config (key/model/URL/test) for whichever provider is
/// currently active.
struct AIProviderSettingsSection: View {
    @State private var settings = AppSettings()

    // Keychain-backed secrets (loaded onAppear, written on change).
    @State private var openaiKey = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var mistralKey = ""
    @State private var qwenKey = ""
    @State private var deepseekKey = ""

    @State private var openaiStatus: TestStatus = .idle
    @State private var anthropicStatus: TestStatus = .idle
    @State private var geminiStatus: TestStatus = .idle
    @State private var mistralStatus: TestStatus = .idle
    @State private var qwenStatus: TestStatus = .idle
    @State private var deepseekStatus: TestStatus = .idle
    @State private var appleStatus: TestStatus = .idle

    var body: some View {
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
        .onAppear { load() }
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
            CredentialTestControls(status: openaiStatus, disabled: openaiKey.isEmpty,
                         onClear: { openaiStatus = .idle }) {
                CredentialTest.run({ openaiStatus = $0 }) {
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
            CredentialTestControls(status: anthropicStatus, disabled: anthropicKey.isEmpty,
                         onClear: { anthropicStatus = .idle }) {
                CredentialTest.run({ anthropicStatus = $0 }) {
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
            CredentialTestControls(status: geminiStatus, disabled: geminiKey.isEmpty,
                         onClear: { geminiStatus = .idle }) {
                CredentialTest.run({ geminiStatus = $0 }) {
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
            CredentialTestControls(status: mistralStatus, disabled: mistralKey.isEmpty,
                         onClear: { mistralStatus = .idle }) {
                CredentialTest.run({ mistralStatus = $0 }) {
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
            CredentialTestControls(status: qwenStatus, disabled: qwenKey.isEmpty,
                         onClear: { qwenStatus = .idle }) {
                CredentialTest.run({ qwenStatus = $0 }) {
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
            CredentialTestControls(status: deepseekStatus, disabled: deepseekKey.isEmpty,
                         onClear: { deepseekStatus = .idle }) {
                CredentialTest.run({ deepseekStatus = $0 }) {
                    await CredentialTester.ai(provider: .deepseek, apiKey: deepseekKey,
                                              model: settings.deepseekModel,
                                              openaiAPIURL: settings.openaiAPIURL)
                }
            }
        case .appleIntelligence:
            LabeledContent("Status", value: appleIntelligenceStatus)
            CredentialTestControls(status: appleStatus, disabled: false,
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

    private func load() {
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
