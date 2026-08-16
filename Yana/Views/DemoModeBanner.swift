import SwiftUI

/// Persistent reminder that the timeline is showing seeded demo content rather than a paired
/// server's real feeds — shown via `.safeAreaInset(edge: .top)` in both the iOS `ReaderScreen`
/// (`Yana/Reader/ReaderHostView.swift`) and the Mac `MacRootView` whenever
/// `AppSettings.hasSkippedServerPairing` is true. See
/// docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md.
struct DemoModeBanner: View {
    var onPairNow: () -> Void
    var onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        icon
                        text
                        Spacer(minLength: 8)
                        dismissButton
                    }
                    pairButton
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    text
                    Spacer(minLength: 8)
                    pairButton
                    dismissButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("demoModeBanner")
    }

    private var icon: some View {
        Image(systemName: "sparkles").foregroundStyle(.orange).accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("You're viewing demo content").font(.subheadline.weight(.semibold))
            Text("Pair a Yana Server to sync your real feeds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pairButton: some View {
        Button("Pair Now", action: onPairNow)
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark").foregroundStyle(.secondary)
        }
        .accessibilityLabel(Text("Dismiss"))
    }
}

#Preview {
    DemoModeBanner(onPairNow: {}, onDismiss: {})
}
