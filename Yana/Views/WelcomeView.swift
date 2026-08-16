import SwiftUI

/// First-launch onboarding, shown once (gated by `AppSettings.hasCompletedOnboarding`). A small
/// paged coordinator over three steps — Welcome, server pairing, and AI mode — with a shared
/// footer (Back / page dots / primary button). Also reused as the re-pairing flow (see
/// `ContentView`'s `.onAppear` gate) for a device that completed onboarding once but no longer
/// has a valid session — that flow starts at `.server` via `initialStep`, not `.welcome`.
struct WelcomeView: View {
    /// Called when onboarding finishes (primary button on the last page). The host flips
    /// `hasCompletedOnboarding` and dismisses.
    var onFinish: () -> Void

    /// Not `private` — `AppState.welcomeInitialStep` (used by `ContentView`'s re-pairing gate)
    /// needs to reference this type.
    enum Step: Int, CaseIterable {
        case welcome, server, aiMode

        var headerIcon: String {
            switch self {
            case .welcome: "newspaper.fill"
            case .server: "server.rack"
            case .aiMode: "sparkles"
            }
        }

        var headerTitle: LocalizedStringKey {
            switch self {
            case .welcome: "Welcome to Yana"
            case .server: "Connect to Your Server"
            case .aiMode: "Choose Your AI"
            }
        }

        var headerSubtitle: LocalizedStringKey {
            switch self {
            case .welcome: "Your own private feed reader — all your sources, gathered on your server."
            case .server: "Yana needs a Yana Server to sign in and sync your feeds."
            case .aiMode: "Summarize articles with your server's AI provider or with Apple Intelligence on this device."
            }
        }
    }

    @State private var step: Step
    @State private var serverState = OnboardingServerState()

    init(onFinish: @escaping () -> Void, initialStep: Step = .welcome) {
        self.onFinish = onFinish
        self._step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            header
            Group {
                switch step {
                case .welcome: WelcomeIntroPage()
                case .server: OnboardingServerPage(onPaired: { step = .aiMode }, state: serverState)
                case .aiMode: OnboardingAIModePage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)

            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: step)
        #if targetEnvironment(macCatalyst)
        // On iOS this view fills whatever full-screen container hosts it, which is correct there.
        // On Mac Catalyst it hosts in its own `WindowGroup` (`WelcomeWindowRoot`), and without a
        // fixed size the window can be resized (or restored from a previous, larger frame)
        // arbitrarily tall — every step then stretches to fill that, leaving a large dead gap
        // below sparser steps like `OnboardingServerPage`. Pinning this to the window's
        // `.defaultSize` (see `YanaApp`) and pairing that with `.windowResizability(.contentSize)`
        // keeps the window itself locked to this size instead.
        .frame(width: 720, height: 640)
        #endif
    }

    // MARK: Chrome

    // Reserves the top inset so the paged content doesn't butt against the status bar. Onboarding
    // can only be completed from the final step's "Finish" button, so there is no Skip affordance.
    private var topBar: some View {
        Color.clear
            .frame(height: 24)
            .padding(.top, 12)
    }

    /// Shared across every step, at a fixed position right below `topBar` — each step only
    /// swaps the icon/title/subtitle text, not the header's presence or placement, so paging
    /// through the wizard never shifts where it sits (previously each page drew its own header
    /// inline with its content, so a step with less content below it — like the server-pairing
    /// step — ended up with its header at a different height than the others).
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: step.headerIcon)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(step.headerTitle)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(step.headerSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
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
                // The final step completes onboarding via "Finish"; the server step shows a
                // single state-driven "Skip"/"Continue" button here, driven by `serverState` (see
                // `OnboardingServerPage`), so it lines up with the Back button like every other
                // step instead of floating inside the form; other steps just advance the pager.
                if step == .aiMode {
                    Button(action: finish) {
                        Text("Finish")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboardingFinishButton")
                } else if step == .server {
                    Button(action: serverState.primaryAction) {
                        Text(serverState.isPaired ? "Continue" : "Skip for now")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(serverState.isSkipping)
                    .accessibilityIdentifier(serverState.isPaired ? "onboardingServerContinueButton" : "onboardingSkipServerButton")
                } else {
                    Button(action: goForward) {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboardingContinueButton")
                }
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

    /// Completes onboarding. The host's `onFinish` kicks off the first foreground sync (see
    /// `InitialSyncGate`, called from `ContentView`) now that pairing is complete.
    private func finish() {
        onFinish()
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
            icon: "server.rack",
            tint: .green,
            title: "Your Own Server",
            detail: "Yana pairs with a Yana Server you control, which aggregates your feeds and syncs them to every device."
        ),
        Feature(
            icon: "sparkles",
            tint: .purple,
            title: "Optional AI",
            detail: "Summarize articles with your server's AI provider, or entirely on-device with Apple Intelligence."
        ),
    ]

    var body: some View {
        ScrollView {
            // The icon/title/subtitle header lives in `WelcomeView.header` now, shared and fixed
            // in position across every step — this page only supplies the feature list below it.
            VStack(spacing: 24) {
                ForEach(features) { feature in
                    featureRow(feature)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
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

#Preview {
    WelcomeView(onFinish: {})
        .environment(AppSettings())
}
