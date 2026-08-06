// Yana/Views/DemoModeBanner.swift
import SwiftUI

/// Persistent reminder that the timeline is showing seeded demo content rather than a paired
/// server's real feeds — shown via `.safeAreaInset(edge: .top)` in both the iOS `ReaderScreen`
/// (`Yana/Reader/ReaderHostView.swift`) and the Mac `MacRootView` whenever
/// `AppSettings.hasSkippedServerPairing` is true. See
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md.
struct DemoModeBanner: View {
    var onPairNow: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're viewing demo content")
                    .font(.subheadline.weight(.semibold))
                Text("Pair a Yana Server to sync your real feeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Pair Now", action: onPairNow)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("demoModeBanner")
    }
}

#Preview {
    DemoModeBanner(onPairNow: {}, onDismiss: {})
}
