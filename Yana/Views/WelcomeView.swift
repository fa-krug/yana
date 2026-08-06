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
    }

    @State private var step: Step

    init(onFinish: @escaping () -> Void, initialStep: Step = .welcome) {
        self.onFinish = onFinish
        self._step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch step {
                case .welcome: WelcomeIntroPage()
                case .server: OnboardingServerPage(onPaired: { step = .aiMode })
                case .aiMode: OnboardingAIModePage()
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

    // Reserves the top inset so the paged content doesn't butt against the status bar. Onboarding
    // can only be completed from the final step's "Finish" button, so there is no Skip affordance.
    private var topBar: some View {
        Color.clear
            .frame(height: 24)
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
                // The final step completes onboarding via "Finish"; the server step's own form
                // supplies a single state-driven "Skip"/"Continue" button (see
                // `OnboardingServerPage`), so this shared footer has nothing to add there; other
                // steps advance the pager.
                if step == .aiMode {
                    Button(action: finish) {
                        Text("Finish")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboardingFinishButton")
                } else if step != .server {
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

    /// Completes onboarding and kicks off a first foreground sync now that pairing is complete.
    private func finish() {
        Task {
            guard let client = AuthenticatedClient.current() else { return }
            _ = try? await SyncEngine(container: AppContainer.shared, client: client).sync()
        }
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
            detail: "Summarize, improve, or translate articles — via your server's AI provider, or entirely on-device with Apple Intelligence."
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
                    Text("Your own private feed reader — all your sources, gathered on your server.")
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

#Preview {
    WelcomeView(onFinish: {})
}
