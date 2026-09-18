#if os(macOS)
import SwiftUI
import AppKit

/// The AppKit twin of `SelectableText` (`SelectableText.swift`, `#if os(iOS)`). Same type name, same
/// stored properties, same contract: a non-editable, non-scrolling text view bridged into SwiftUI so
/// the reader's body text is fully selectable with the system services menu, sizing itself to the
/// width SwiftUI proposes so it lays out exactly like the `Text` it replaces. Call sites in
/// `ArticleBlockView` are unconditional and never learn which one they got.
///
/// Links carry `.link` and are routed through `onOpenLink` (via the reader's link policy) rather
/// than navigated by the text view itself; everything else is plain, selectable prose.
///
/// **This deliberately builds a bare `NSTextView`, never `NSTextView.scrollableTextView()`.** That
/// factory wraps the text view in an `NSScrollView`, and `ReaderBlockViewController` locates the
/// reader's reading position by finding the one `NSScrollView` in the hosting controller's tree —
/// see the long comment on its `bodyScrollView`. A second scroll view per text run would make that
/// lookup ambiguous, which on iOS is exactly the trap that once produced a reading position the
/// reader never had.
struct SelectableText: NSViewRepresentable {
    let attributedText: NSAttributedString
    var onOpenLink: (URL) -> Void = { _ in }
    /// The body segment whose only text view this is, when it is one (a coalesced text run, a
    /// top-level code block, the lead/standalone image's caption). `ReaderBlockViewController`
    /// locates the view for the current find match by this tag to scroll the match itself on
    /// screen, not just its segment. `nil` for a text view that shares its segment with others.
    var findSegment: Int? = nil

    func makeNSView(context: Context) -> ReaderTextView {
        let textView = ReaderTextView(frame: .zero)
        // Opt into the legacy TextKit 1 layout engine, matching iOS. For static, non-editable,
        // non-scrolling prose (all this view ever holds) TextKit 1 has markedly lower per-view setup
        // and sizing overhead than the TextKit 2 default — and there is one of these per body text
        // run, so it adds up. Touching `layoutManager` before first layout performs the one-time
        // downgrade. On AppKit that property is optional, so this reads as a discard of an optional.
        _ = textView.layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        // AppKit-only hygiene with no UIKit counterpart: an `NSTextView` still accepts first
        // responder and draws an insertion point in some configurations even when not editable, and
        // a field editor would additionally swallow Return/Tab. Neither is wanted for body prose.
        textView.isFieldEditor = false
        // `isScrollEnabled = false` has no AppKit equivalent. The same intent — "do not scroll, grow
        // to fit the text, let the enclosing SwiftUI ScrollView do the scrolling" — is spelled as
        // an unbounded max size plus vertical-only resizing with the container tracking the view's
        // width, so the text reflows at whatever width SwiftUI proposes and the height follows.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false                    // AppKit's `backgroundColor = .clear`
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Links come from `.link` attributes, not from AppKit's own detection pass — which would
        // otherwise turn bare URLs in the prose into clickable text this view opens itself,
        // bypassing the reader's link policy. (UIKit's equivalent is `dataDetectorTypes = []`.)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(named: "AccentColor") ?? NSColor.controlAccentColor
        ]
        textView.delegate = context.coordinator
        // Never let the text view stretch or squash itself away from its intrinsic content height.
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        return textView
    }

    func updateNSView(_ textView: ReaderTextView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        textView.findSegment = findSegment
        // Rebuilding produces an equal string for unchanged content, so this no-ops (and keeps the
        // current selection) unless the text actually changed — e.g. a font/size change or reload.
        if textView.readerAttributedString != attributedText {
            textView.readerAttributedString = attributedText
            textView.invalidateIntrinsicContentSize()
        }
    }

    /// Report the height the text needs at the width SwiftUI proposes, so the block lays out at its
    /// natural height inside the vertical stack.
    ///
    /// `NSTextView` has no `sizeThatFits`, so the measurement is done by hand: pin the text
    /// container to the proposed width, force a full synchronous TextKit layout, and read back the
    /// rect the glyphs actually used. SwiftUI calls this on every layout pass, the body width is
    /// stable, and the string only changes on a font/size change or reload, so the last measurement
    /// is memoized (keyed by width + string) on the coordinator exactly as on iOS.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReaderTextView, context: Context) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        } else {
            width = nsView.bounds.width > 0 ? nsView.bounds.width : 1000
        }
        let cache = context.coordinator
        let current = nsView.readerAttributedString
        if let cachedWidth = cache.measuredWidth, abs(cachedWidth - width) < 0.5,
           let cachedHeight = cache.measuredHeight,
           let cachedString = cache.measuredString, cachedString.isEqual(current) {
            return CGSize(width: width, height: cachedHeight)
        }
        let height = ceil(nsView.measuredHeight(fittingWidth: width))
        cache.measuredWidth = width
        cache.measuredHeight = height
        cache.measuredString = current
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenLink: (URL) -> Void
        /// Memoized `sizeThatFits` result (see the method) — reused while width + string are unchanged.
        var measuredWidth: CGFloat?
        var measuredHeight: CGFloat?
        var measuredString: NSAttributedString?
        init(onOpenLink: @escaping (URL) -> Void) { self.onOpenLink = onOpenLink }

        /// Route link clicks through the reader's link policy instead of letting the text view open
        /// them itself, matching in-body SwiftUI links.
        ///
        /// UIKit's `textView(_:primaryActionFor:defaultAction:)` expresses "I am handling this" by
        /// returning a replacement action; AppKit expresses it by returning `true`. Returning
        /// `false` would hand the URL to `NSWorkspace` behind the policy's back, so the only
        /// non-handled case is a link whose value is not a URL at all.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            switch link {
            case let value as URL: url = value
            case let value as String: url = URL(string: value)
            default: url = nil
            }
            guard let url else { return false }
            onOpenLink(url)
            return true
        }
    }
}

/// The `NSTextView` `SelectableText` hosts. A subclass only so the reader can tell its text views
/// apart when walking the view tree: `findSegment` tags the one text view drawing a given body
/// segment (see `SelectableText.findSegment`), which is how the current find match is scrolled to
/// its own line rather than to the top of a long run of prose.
final class ReaderTextView: NSTextView {
    var findSegment: Int?

    /// The text this view draws, under the name its iOS twin also exposes. `NSTextView` has no
    /// `attributedText`: reading `attributedString()` returns a snapshot copy and writing goes
    /// through `textStorage`, so both halves are spelled out here once rather than at every call
    /// site in the representable and in `ReaderBlockViewController`'s find reveal.
    var readerAttributedString: NSAttributedString {
        get { textStorage ?? NSAttributedString() }
        set { textStorage?.setAttributedString(newValue) }
    }

    /// Height the current text needs at `width`. The container is pinned to the measured width for
    /// the duration of the layout — `widthTracksTextView` would otherwise re-derive it from the
    /// view's *current* frame, which during a SwiftUI sizing pass is not yet the width being
    /// proposed — and restored afterwards so normal layout keeps following the frame.
    func measuredHeight(fittingWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        let tracked = container.widthTracksTextView
        let previousSize = container.size
        container.widthTracksTextView = false
        container.size = CGSize(width: max(0, width - textContainerInset.width * 2),
                                height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        container.size = previousSize
        container.widthTracksTextView = tracked
        return used + textContainerInset.height * 2
    }
}
#endif
