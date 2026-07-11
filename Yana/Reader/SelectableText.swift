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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
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

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        // Rebuilding produces an equal string for unchanged content, so this no-ops (and keeps the
        // current selection) unless the text actually changed — e.g. a font/size change or reload.
        if textView.attributedText != attributedText {
            textView.attributedText = attributedText
            textView.invalidateIntrinsicContentSize()
        }
    }

    /// Report the height the text needs at the width SwiftUI proposes, so the block lays out at its
    /// natural height inside the vertical stack (iOS 16+ representable sizing).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        } else {
            width = uiView.bounds.width > 0 ? uiView.bounds.width : 1000
        }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitting.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenLink: (URL) -> Void
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

/// Builds the `NSAttributedString`s that back `SelectableText`. Mirrors the SwiftUI
/// `attributedString(from:)` styling (bold/italic/code/strikethrough + links) but in UIKit terms,
/// baking in the point size, weight, and the reader's chosen typeface `design` — the SwiftUI
/// `.fontDesign` modifier only reaches SwiftUI `Text`, not a hosted `UITextView`.
enum ReaderAttributedText {
    static func make(runs: [InlineRun], baseSize: CGFloat, weight: UIFont.Weight = .regular,
                     design: UIFontDescriptor.SystemDesign, color: UIColor = .label) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendRuns(runs, into: result, baseSize: baseSize, weight: weight, design: design, color: color)
        return result
    }

    /// Vertical gap between coalesced blocks inside one `SelectableText`, matching the reader's
    /// top-level VStack spacing so a merged text run looks identical to separate blocks.
    private static let blockSpacing: CGFloat = 16
    /// Extra space above a heading (on top of the preceding block's trailing gap), mirroring the
    /// former per-heading `.padding(.top, 4)`.
    private static let headingSpacingBefore: CGFloat = 4

    /// Build one attributed string spanning several consecutive top-level text blocks (paragraphs
    /// and headings) so a whole run of prose renders through a single `UITextView` instead of one
    /// per block — the reader's dominant per-page cost. Inter-block spacing and heading emphasis are
    /// baked into per-paragraph `NSParagraphStyle`s + fonts so the merged run lays out exactly like
    /// the individual blocks it replaces. Non-text blocks (images, embeds, lists, quotes, code,
    /// dividers) are not passed here — they break a run and render standalone.
    static func make(blocks: [Block], baseSize: CGFloat,
                     design: UIFontDescriptor.SystemDesign, color: UIColor = .label) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let isLast = i == blocks.count - 1
            let runs: [InlineRun]
            let size: CGFloat
            let weight: UIFont.Weight
            let spacingBefore: CGFloat
            switch block {
            case .paragraph(let r):
                runs = r; size = baseSize; weight = .regular; spacingBefore = 0
            case .heading(let level, let r):
                runs = r; size = headingSize(baseSize, level); weight = .bold
                spacingBefore = headingSpacingBefore
            default:
                continue   // only paragraphs/headings are coalesced; callers pass nothing else
            }
            let start = result.length
            appendRuns(runs, into: result, baseSize: size, weight: weight, design: design, color: color)
            if !isLast { result.append(NSAttributedString(string: "\n")) }
            // Apply the paragraph style over the whole paragraph, including its terminating newline,
            // so `paragraphSpacing` (the gap after) takes effect. The last block carries no trailing
            // gap — the enclosing VStack spaces it from the next segment.
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = isLast ? 0 : blockSpacing
            style.paragraphSpacingBefore = spacingBefore
            result.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: start, length: result.length - start))
        }
        return result
    }

    /// Body-relative heading point size, mirroring `BlockNodeView.headingSize` so coalesced and
    /// standalone headings match.
    static func headingSize(_ baseSize: CGFloat, _ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize * 1.5
        case 2: return baseSize * 1.3
        case 3: return baseSize * 1.15
        default: return baseSize * 1.05
        }
    }

    private static func appendRuns(_ runs: [InlineRun], into result: NSMutableAttributedString,
                                   baseSize: CGFloat, weight: UIFont.Weight,
                                   design: UIFontDescriptor.SystemDesign, color: UIColor) {
        let baseDescriptor = systemDescriptor(size: baseSize, weight: weight, design: design)
        for run in runs {
            var traits = baseDescriptor.symbolicTraits
            if run.styles.contains(.bold) { traits.insert(.traitBold) }
            if run.styles.contains(.italic) { traits.insert(.traitItalic) }
            var descriptor = baseDescriptor.withSymbolicTraits(traits) ?? baseDescriptor
            // Inline `code` pins a monospaced face at the same size, like the SwiftUI `.code` intent.
            if run.styles.contains(.code) {
                descriptor = descriptor.withDesign(.monospaced) ?? descriptor
            }
            let font = UIFont(descriptor: descriptor, size: baseSize)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if run.styles.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link, let url = URL(string: link) {
                attrs[.link] = url
            }
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
    }

    static func make(string: String, size: CGFloat, weight: UIFont.Weight = .regular,
                     design: UIFontDescriptor.SystemDesign, color: UIColor = .label) -> NSAttributedString {
        let font = UIFont(descriptor: systemDescriptor(size: size, weight: weight, design: design), size: size)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private static func systemDescriptor(size: CGFloat, weight: UIFont.Weight,
                                         design: UIFontDescriptor.SystemDesign) -> UIFontDescriptor {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
    }
}

extension ArticleFont {
    /// UIKit equivalent of `design`, for text baked into a `UITextView` (which the SwiftUI
    /// `.fontDesign` modifier does not reach).
    var uiDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}
