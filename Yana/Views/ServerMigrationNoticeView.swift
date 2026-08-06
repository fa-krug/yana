import SwiftUI

/// Full-screen, dismissable notice shown once to devices that already completed onboarding
/// before Yana required a server (see `ServerMigrationEligibility` and the design doc at
/// docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md). Presented both as an
/// iOS `.fullScreenCover` (`ContentView`) and inside its own Mac window
/// (`ServerMigrationNoticeWindowRoot`).
struct ServerMigrationNoticeView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Yana Now Runs on a Server")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Since you last opened Yana, it’s grown from a fully on-device app into a lightweight companion for your own self-hosted Yana Server — the server now fetches your feeds and does the heavy lifting, and this app just shows you the results.")
                        Link(destination: URL(string: "https://yana.fa-krug.de/server.html")!) {
                            Text("Learn More")
                        }

                        Text("Prefer things exactly as they were? Yana 1.1.0 is still available — the last fully self-contained release, no server required.")
                        Link(destination: URL(string: "https://github.com/fa-krug/yana/releases/tag/v1.1.0")!) {
                            Text("Get Yana 1.1.0")
                        }

                        Text("If this change isn’t for you, just let me know and I’ll refund your purchase.")
                        Link(destination: URL(string: "mailto:info@fa-krug.de")!) {
                            Text("Request a Refund")
                        }
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var footer: some View {
        Button(action: onDismiss) {
            Text("Continue")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("serverMigrationNoticeDismissButton")
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

#Preview {
    ServerMigrationNoticeView(onDismiss: {})
}
