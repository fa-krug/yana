import SwiftUI

/// Shown instead of the reader when the very first sync after pairing exhausted its retries.
/// Without this the user landed on the empty-library "add your first feed" state against a
/// server that is actually full of articles (audit U3).
struct InitialSyncFailedView: View {
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Reach Your Server", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Pairing succeeded, but your articles couldn't be loaded. Check your connection and try again.")
        } actions: {
            Button("Try Again", action: onRetry).buttonStyle(.borderedProminent)
        }
    }
}
