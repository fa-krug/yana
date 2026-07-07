import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// First-launch onboarding, shown once (gated by `AppSettings.hasCompletedOnboarding`). A small
/// paged coordinator over three steps — Welcome, optional AI setup, and a first feed — with a
/// shared footer (Back / page dots / primary button) and a Skip affordance on the optional steps.
struct WelcomeView: View {
    /// Called when onboarding finishes (primary button on the last page, or Skip). The host flips
    /// `hasCompletedOnboarding` and dismisses.
    var onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, ai, feeds
    }

    @State private var step: Step = .welcome
    @State private var settings = AppSettings()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch step {
                case .welcome: WelcomeIntroPage()
                case .ai: OnboardingAIPage(settings: settings)
                case .feeds: OnboardingFeedsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)

            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Spacer()
            if step != .welcome {
                Button(String(localized: "Skip"), action: onFinish)
                    .font(.body)
                    .accessibilityIdentifier("onboardingSkipButton")
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            pageDots
            HStack(spacing: 12) {
                if step != .welcome {
                    Button(action: goBack) {
                        Text("Back")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboardingBackButton")
                }
                Button(action: goForward) {
                    Group {
                        if step == .feeds {
                            Text("Get Started")
                        } else {
                            Text("Continue")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboardingContinueButton")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func goForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish()
            return
        }
        step = next
    }
}

// MARK: - Page 1: Welcome / feature highlights

private struct WelcomeIntroPage: View {
    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private let features: [Feature] = [
        Feature(
            icon: "square.stack.3d.up",
            tint: .orange,
            title: "Everything in One Timeline",
            detail: "RSS, YouTube, Reddit, podcasts, and whole websites flow into a single endless timeline you swipe through."
        ),
        Feature(
            icon: "tag",
            tint: .blue,
            title: "Organize with Tags",
            detail: "Tag your feeds to filter the timeline, and star articles to keep them around."
        ),
        Feature(
            icon: "lock.shield",
            tint: .green,
            title: "Private by Design",
            detail: "Everything is fetched and stored on your device. No account, no server, no tracking."
        ),
        Feature(
            icon: "sparkles",
            tint: .purple,
            title: "Optional AI",
            detail: "Bring your own key to summarize, improve, or translate articles — entirely opt-in."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Welcome to Yana")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Your own private feed reader — all your sources, gathered on your device.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 24) {
                    ForEach(features) { feature in
                        featureRow(feature)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("welcomeScreen")
    }

    private func featureRow(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: feature.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(feature.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Page 2: AI configuration (basics only)

private struct OnboardingAIPage: View {
    @Bindable var settings: AppSettings

    @State private var apiKey = ""
    @State private var status: TestStatus = .idle

    private var provider: AIProvider { settings.activeAIProvider }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.aiModel(for: provider) },
            set: { settings.setAIModel($0, for: provider) }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.activeAIProvider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                } label: {
                    Label("Active Provider", systemImage: "sparkles")
                        .labelStyle(.tintedIcon(.purple))
                }
                providerConfig
            } header: {
                Text("AI Provider")
            } footer: {
                Text("Optional. Bring your own key to summarize, improve, or translate articles. You can change this anytime in Settings.")
            }
        }
        .accessibilityIdentifier("onboardingAIScreen")
        .onAppear(perform: loadKey)
        .onChange(of: provider) { _, _ in loadKey() }
    }

    @ViewBuilder
    private var providerConfig: some View {
        switch provider {
        case .none:
            Text("Set this up later in Settings.")
                .foregroundStyle(.secondary)
        case .appleIntelligence:
            LabeledContent("Status", value: appleIntelligenceStatus)
            testButton(disabled: false) {
                let available = AppleIntelligenceClient().availability == .available
                status = available ? .valid : .invalid(appleIntelligenceStatus)
            }
        default:
            SecureField("API Key", text: $apiKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(status == .testing)
                .onChange(of: apiKey) { _, value in
                    if let item = provider.apiKeyItem {
                        KeychainService.saveAPIKey(value, for: item)
                    }
                    status = .idle
                }
            if provider == .openai {
                TextField("API URL", text: $settings.openaiAPIURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(status == .testing)
            }
            Picker("Model", selection: modelBinding) {
                ForEach(provider.models, id: \.self) { Text($0).tag($0) }
            }
            testButton(disabled: apiKey.isEmpty) {
                runTest {
                    await CredentialTester.ai(
                        provider: provider,
                        apiKey: apiKey,
                        model: settings.aiModel(for: provider),
                        openaiAPIURL: settings.openaiAPIURL
                    )
                }
            }
        }
    }

    /// A "Test" button plus its inline status row (mirrors the Settings pattern, minus the shared
    /// private helpers, which are scoped to `SettingsScreenView`).
    @ViewBuilder
    private func testButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("Test")
                if status == .testing {
                    Spacer()
                    Text("Testing…").foregroundStyle(.secondary)
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

    private func runTest(_ op: @escaping () async -> CredentialTestError?) {
        status = .testing
        Task {
            let error = await op()
            status = error.map { .invalid($0.localizedMessage) } ?? .valid
        }
    }

    private func loadKey() {
        status = .idle
        apiKey = provider.apiKeyItem.flatMap { KeychainService.loadAPIKey(for: $0) } ?? ""
    }

    private var appleIntelligenceStatus: String {
        switch AppleIntelligenceClient().availability {
        case .available: String(localized: "Available")
        case .deviceNotEligible: String(localized: "Not available on this device")
        case .notEnabled: String(localized: "Turn on Apple Intelligence in Settings")
        case .modelNotReady: String(localized: "Model downloading…")
        }
    }
}

// MARK: - Page 3: First feed (add or import)

private struct OnboardingFeedsPage: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showCreateFeed = false
    @State private var isImporting = false
    @State private var addedCount = 0
    @State private var toast: ToastMessage?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Add Your First Feed")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Add a feed or import an OPML file to get started. You can always add more later.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button {
                        showCreateFeed = true
                    } label: {
                        Label("Add a Feed", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Feeds", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if addedCount > 0 {
                    Label("You're all set.", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("onboardingFeedsScreen")
        .animation(.easeInOut, value: addedCount)
        .sheet(isPresented: $showCreateFeed) {
            NavigationStack {
                FeedEditorView(feed: nil) { newFeed in
                    guard newFeed.enabled else { return }
                    updateOne(newFeed)
                    addedCount += 1
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .toast($toast)
    }

    private func updateOne(_ feed: Feed) {
        UpdateActivity.shared.restart {
            let count = await AggregationService(context: modelContext).update(feed: feed)
            guard !Task.isCancelled else { return }
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feed.name))
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
            toast = ToastMessage(text: String(localized: "Could not read the file."), style: .error)
            return
        }
        let r = FeedPortability.importOPML(xml, context: modelContext)
        addedCount += r.imported
        toast = ToastMessage(text: String(localized: "Imported \(r.imported) feeds, skipped \(r.skipped)."))
        // Imported feeds aren't auto-fetched — kick a full update so their articles appear.
        if r.imported > 0 {
            UpdateActivity.shared.restart {
                _ = await AggregationService(context: modelContext).updateAll()
            }
        }
    }
}

#Preview {
    WelcomeView(onFinish: {})
}
