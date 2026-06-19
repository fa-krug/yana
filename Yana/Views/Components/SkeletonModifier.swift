// Yana/Views/Components/SkeletonModifier.swift
import SwiftUI

/// Native placeholder treatment: system redaction plus a slow, subtle opacity pulse.
/// No custom shimmer gradient — keep it "native & invisible". When `active` is false the
/// content renders normally.
private struct SkeletonModifier: ViewModifier {
    let active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        if active {
            content
                .redacted(reason: .placeholder)
                .opacity(pulse ? 0.45 : 0.85)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
                .accessibilityHidden(true)
        } else {
            content
        }
    }
}

extension View {
    /// Render `self` as a redacted, gently pulsing placeholder while `active`.
    func skeleton(active: Bool) -> some View { modifier(SkeletonModifier(active: active)) }
}
