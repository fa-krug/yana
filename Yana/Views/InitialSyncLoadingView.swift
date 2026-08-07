import SwiftUI

/// Shown in place of the reader while the device's very first sync (right after pairing) is still
/// filling the local mirror -- see `InitialSyncGate` for why this needs to block rather than let
/// the reader render against a still-settling timeline.
struct InitialSyncLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Setting Up Your Library")
                .font(.headline)
            Text("Fetching your feeds and articles from the server. This may take a moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .accessibilityIdentifier("initialSyncLoadingScreen")
    }
}

#Preview {
    InitialSyncLoadingView()
}
