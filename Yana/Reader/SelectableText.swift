#if os(iOS)
import SwiftUI
import UIKit

/// A non-editable, non-scrolling `UITextView` bridged into SwiftUI so the reader's body text is
/// fully selectable with the system edit menu (Copy, Look Up, Translate, Share…). This is richer
/// and more reliable than SwiftUI's per-`Text` `.textSelection` — which offers no edit menu and is
/// flaky inside the reader's `UIPageViewController` — while still sizing itself to the width SwiftUI
/// proposes so it lays out exactly like the `Text` it replaces.
///
/// Links carry `.link` and are routed through `onOpenLink` (via the reader's link policy) rather
/// than navigated by the text view itself; everything else is plain, selectable prose.
struct SelectableText: UIViewRepresentable {
    let attributedText: NSAttributedString
    var onOpenLink: (URL) -> Void = { _ in }
    /// The body segment whose only text view this is, when it is one (a coalesced text run, a
    /// top-level code block, the lead/standalone image's caption). `ReaderBlockViewController`
    /// locates the view for the current find match by this tag to scroll the match itself on
    /// screen, not just its segment. `nil` for a text view that shares its segment with others.
    var findSegment: Int? = nil

    func makeUIView(context: Context) -> ReaderTextView {
        let textView = ReaderTextView()
        // Opt into the legacy TextKit 1 layout engine. For static, non-editable, non-scrolling prose
        // (all this view ever holds) TextKit 1 has markedly lower per-view setup and sizing overhead
        // than the iOS-16 TextKit 2 default — and there is one of these per body text run, so it adds
        // up. Touching `layoutManager` before first layout performs the one-time downgrade.
        _ = textView.layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false          // let the SwiftUI ScrollView scroll; size to content
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false   // sizes already fold in Dynamic Type
        textView.dataDetectorTypes = []            // links come from `.link` attributes, not detection
        textView.linkTextAttributes = [.foregroundColor: UIColor(named: "AccentColor") ?? .tintColor]
        textView.delegate = context.coordinator
        // Never let the text view stretch or squash itself away from its intrinsic content height.
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: ReaderTextView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        textView.findSegment = findSegment
        // Rebuilding produces an equal string for unchanged content, so this no-ops (and keeps the
        // current selection) unless the text actually changed — e.g. a font/size change or reload.
        if textView.attributedText != attributedText {
            textView.attributedText = attributedText
            textView.invalidateIntrinsicContentSize()
        }
    }

    /// Report the height the text needs at the width SwiftUI proposes, so the block lays out at its
    /// natural height inside the vertical stack (iOS 16+ representable sizing).
    ///
    /// `sizeThatFits` runs a full synchronous TextKit layout to measure height, and SwiftUI calls it
    /// on every layout pass. The body width is stable and the string only changes on a font/size
    /// change or reload, so memoize the last measurement (keyed by width + string) on the coordinator
    /// — the pager's repeated passes and the post-prewarm on-screen appearance then reuse the height
    /// instead of re-laying out the glyphs each time.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReaderTextView, context: Context) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        } else {
            width = uiView.bounds.width > 0 ? uiView.bounds.width : 1000
        }
        let cache = context.coordinator
        if let cachedWidth = cache.measuredWidth, abs(cachedWidth - width) < 0.5,
           let cachedHeight = cache.measuredHeight,
           let cachedString = cache.measuredString, cachedString.isEqual(uiView.attributedText) {
            return CGSize(width: width, height: cachedHeight)
        }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(fitting.height)
        cache.measuredWidth = width
        cache.measuredHeight = height
        cache.measuredString = uiView.attributedText
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenLink: (URL) -> Void
        /// Memoized `sizeThatFits` result (see the method) — reused while width + string are unchanged.
        var measuredWidth: CGFloat?
        var measuredHeight: CGFloat?
        var measuredString: NSAttributedString?
        init(onOpenLink: @escaping (URL) -> Void) { self.onOpenLink = onOpenLink }

        /// Route link taps through the reader's link policy instead of letting the text view open
        /// them itself, matching in-body SwiftUI links.
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            if case let .link(url) = textItem.content {
                return UIAction { [onOpenLink] _ in onOpenLink(url) }
            }
            return defaultAction
        }
    }
}

/// The `UITextView` `SelectableText` hosts. A subclass only so the reader can tell its text views
/// apart when walking the view tree: `findSegment` tags the one text view drawing a given body
/// segment (see `SelectableText.findSegment`), which is how the current find match is scrolled to
/// its own line rather than to the top of a long run of prose.
final class ReaderTextView: UITextView {
    var findSegment: Int?

    /// The text this view draws, under a name both platforms share. `NSTextView` has no
    /// `attributedText` at all (its content lives in `textStorage`), so the reader's find machinery
    /// would otherwise have to fork purely over a property name. Here it is a straight alias.
    var readerAttributedString: NSAttributedString {
        get { attributedText }
        set { attributedText = newValue }
    }
}

#endif
