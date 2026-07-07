import SwiftUI

/// First-launch welcome / onboarding screen. Introduces what Yana is (a private, on-device feed
/// aggregator) and its key features, then dismisses via a "Get Started" button. Shown once, gated
/// by `AppSettings.hasCompletedOnboarding`.
struct WelcomeView: View {
    /// Called when the user taps "Get Started". The host flips `hasCompletedOnboarding` and
    /// dismisses.
    var onGetStarted: () -> Void

    /// One feature highlight row.
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 32) {
                    header
                    VStack(spacing: 24) {
                        ForEach(features) { feature in
                            featureRow(feature)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }

            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .accessibilityIdentifier("welcomeScreen")
    }

    private var header: some View {
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

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("welcomeGetStartedButton")
        }
        .background(.bar)
    }
}

#Preview {
    WelcomeView(onGetStarted: {})
}
