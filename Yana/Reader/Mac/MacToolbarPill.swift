import SwiftUI

/// A hand-rolled joined "segmented pill" for Mac Catalyst window toolbars, used by both the reader
/// window (`MacRootView`) and the Feeds screen so the two toolbars read as one design.
///
/// Catalyst renders a SwiftUI `ControlGroup` empty after toolbar re-validation, and lays out
/// individual bordered toolbar buttons as cramped, squashed capsules — so grouped primary actions
/// are built here as borderless icon segments sharing a single capsule background (no inner
/// dividers, which read as clutter inside a button pill).
struct MacToolbarPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .background(
                Capsule(style: .continuous)
                    .fill(.quaternary)
                    .overlay(Capsule(style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            )
            .clipShape(Capsule(style: .continuous))
    }
}

/// One icon-only segment of a `MacToolbarPill`: a borderless button sized to a fixed slot so the
/// segments line up and never look squashed.
struct MacPillButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(Text(title))
    }
}
