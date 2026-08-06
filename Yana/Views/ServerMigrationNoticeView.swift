import SwiftUI

/// Full-screen, dismissable notice shown once to devices that already completed onboarding
/// before Yana required a server (see `ServerMigrationEligibility` and the design doc at
/// docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md). Presented both as an
/// iOS `.fullScreenCover` (`ContentView`) and inside its own Mac window
/// (`ServerMigrationNoticeWindowRoot`).
struct ServerMigrationNoticeView: View {
    var onDismiss: () -> Void

    private struct Option: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let detail: LocalizedStringKey
        let actionTitle: LocalizedStringKey
        let url: URL
    }

    private let options: [Option] = [
        Option(
            icon: "server.rack",
            tint: .green,
            detail: "Since you last opened Yana, it’s grown from a fully on-device app into a lightweight companion for your own self-hosted Yana Server — the server now fetches your feeds and does the heavy lifting, and this app just shows you the results.",
            actionTitle: "Learn More",
            url: URL(string: "https://yana.fa-krug.de/server.html")!
        ),
        Option(
            icon: "clock.arrow.circlepath",
            tint: .orange,
            detail: "Prefer things exactly as they were? Yana 1.1.0 is still available — the last fully self-contained release, no server required.",
            actionTitle: "Get Yana 1.1.0",
            url: URL(string: "https://github.com/fa-krug/yana/releases/tag/v1.1.0")!
        ),
        Option(
            icon: "arrow.uturn.backward.circle",
            tint: .purple,
            detail: "If this change isn’t for you, just let me know and I’ll refund your purchase.",
            actionTitle: "Request a Refund",
            url: URL(string: "mailto:info@fa-krug.de")!
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Yana Now Runs on a Server")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text("A quick update on what changed, and your options.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 16) {
                        ForEach(options) { option in
                            optionCard(option)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func optionCard(_ option: Option) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: option.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(option.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(option.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Link(destination: option.url) {
                    Text(option.actionTitle)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footer: some View {
        HStack {
            #if targetEnvironment(macCatalyst)
            Spacer()
            continueButton
            #else
            continueButton
                .frame(maxWidth: .infinity)
            #endif
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var continueButton: some View {
        Button(action: onDismiss) {
            Text("Continue")
                .font(.headline)
                #if !targetEnvironment(macCatalyst)
                .frame(maxWidth: .infinity)
                #endif
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("serverMigrationNoticeDismissButton")
    }
}

#Preview {
    ServerMigrationNoticeView(onDismiss: {})
}
