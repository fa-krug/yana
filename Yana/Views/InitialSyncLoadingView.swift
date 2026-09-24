import SwiftUI

/// Shown in place of the reader while the device's very first sync (right after pairing) is still
/// filling the local mirror -- see `InitialSyncGate` for why this needs to block rather than let
/// the reader render against a still-settling timeline.
///
/// Also reused while "Remove Server Connection" swaps the library for demo content, with its own copy.
struct InitialSyncLoadingView: View {
    var title: LocalizedStringKey = "Setting Up Your Library"
    var message: LocalizedStringKey = "Fetching your feeds and articles from the server. This may take a moment."

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(PlatformColor.yanaWindowBackground).ignoresSafeArea())
        .accessibilityIdentifier("initialSyncLoadingScreen")
    }
}

#Preview {
    InitialSyncLoadingView()
}
