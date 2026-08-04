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
                    Text("Yana Now Requires a Server")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Starting with this version, Yana needs to connect to a Yana Server to fetch and manage your feeds and articles.")
                        Link(destination: URL(string: "https://yana.fa-krug.de/server.html")!) {
                            Text("Learn more about the Yana Server")
                        }

                        Text("Would rather not switch? Yana 1.1.0 — the last fully self-contained, server-free release — remains open source.")
                        Link(destination: URL(string: "https://github.com/fa-krug/yana/releases/tag/v1.1.0")!) {
                            Text("Build Yana 1.1.0 from Source")
                        }

                        Text("Don't want to use Yana anymore?")
                        Link(destination: URL(string: "mailto:info@fa-krug.de")!) {
                            Text("Email info@fa-krug.de for a Refund")
                        }
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
            }
            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var footer: some View {
        Button(action: onDismiss) {
            Text("Got It")
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
