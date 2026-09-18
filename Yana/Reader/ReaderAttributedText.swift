import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The reader's attributed-text builder and its find-highlight fills, shared verbatim by both
/// platforms.
///
/// These used to live at the bottom of `SelectableText.swift`. They are **not view code** — they
/// build an `NSAttributedString` and pick two colors — and the view half of that file forks
/// completely between `UITextView` and `NSTextView`, so leaving them there would have handed each
/// platform its own copy of the builder. That is specifically dangerous for
/// `ReaderAttributedText.make(blocks:)`: `FindUnit.textViewOffset` (`ArticleFind.swift`) mirrors
/// this method's join arithmetic character for character, and `ArticleFindTests` pins the two
/// against each other. Two copies means the find index can silently point at the wrong characters
/// on whichever platform the test does not run. One copy, one arithmetic.

/// The two highlight fills "Find in Article" paints: a soft wash over every match and a stronger
/// one over the current match, in both AppKit/UIKit (`SelectableText`) and SwiftUI (`Text`) terms
/// so the two text paths look the same. `.systemOrange`, `.systemYellow` and
/// `withAlphaComponent(_:)` all exist on `NSColor` with the same meaning, so only the SwiftUI
/// bridge (`Color(nsColor:)` vs `Color(uiColor:)`) needed a fork.
enum FindHighlightStyle {
    static func platformColor(isCurrent: Bool) -> PlatformColor {
        isCurrent
            ? PlatformColor.systemOrange.withAlphaComponent(0.7)
            : PlatformColor.systemYellow.withAlphaComponent(0.35)
    }

    static func color(isCurrent: Bool) -> Color {
        #if os(macOS)
        Color(nsColor: platformColor(isCurrent: isCurrent))
        #else
        Color(uiColor: platformColor(isCurrent: isCurrent))
        #endif
    }

    /// Paints `highlights` (ranges in `text`'s own UTF-16 offsets, shifted by `offset` into
    /// `result`) as background fills, skipping any range that does not fit -- a highlight computed
    /// against text this string does not hold must never crash the renderer.
    static func apply(_ highlights: [FindHighlightRange], to result: NSMutableAttributedString, offset: Int = 0) {
        for highlight in highlights {
            let range = NSRange(location: offset + highlight.range.location, length: highlight.range.length)
            guard range.location >= 0, NSMaxRange(range) <= result.length else { continue }
            result.addAttribute(.backgroundColor, value: platformColor(isCurrent: highlight.isCurrent), range: range)
        }
    }
}

/// Builds the `NSAttributedString`s that back `SelectableText`. Mirrors the SwiftUI
/// `attributedString(from:)` styling (bold/italic/code/strikethrough + links) but in AppKit/UIKit
/// terms, baking in the point size, weight, and the reader's chosen typeface `design` — the SwiftUI
/// `.fontDesign` modifier only reaches SwiftUI `Text`, not a hosted text view.
enum ReaderAttributedText {
    static func make(runs: [InlineRun], baseSize: CGFloat, weight: PlatformFont.Weight = .regular,
                     design: PlatformFontDescriptor.SystemDesign, color: PlatformColor = .yanaLabel,
                     highlights: [FindHighlightRange] = []) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendRuns(runs, into: result, baseSize: baseSize, weight: weight, design: design, color: color)
        FindHighlightStyle.apply(highlights, to: result)
        return result
    }

    /// Vertical gap between coalesced blocks inside one `SelectableText`, matching the reader's
    /// top-level VStack spacing so a merged text run looks identical to separate blocks.
    private static let blockSpacing: CGFloat = 16
    /// Extra space above a heading (on top of the preceding block's trailing gap), mirroring the
    /// former per-heading `.padding(.top, 4)`.
    private static let headingSpacingBefore: CGFloat = 4

    /// Build one attributed string spanning several consecutive top-level text blocks (paragraphs
    /// and headings) so a whole run of prose renders through a single hosted text view instead of
    /// one per block — the reader's dominant per-page cost. Inter-block spacing and heading emphasis
    /// are baked into per-paragraph `NSParagraphStyle`s + fonts so the merged run lays out exactly
    /// like the individual blocks it replaces. Non-text blocks (images, embeds, lists, quotes, code,
    /// dividers) are not passed here — they break a run and render standalone.
    ///
    /// `highlights(i)` returns the find highlights of block `i`, in that block's own text offsets;
    /// they are shifted to where the block's text landed in the merged string. `FindUnit`'s
    /// `textViewOffset` mirrors that same arithmetic (each block's UTF-16 length plus one newline),
    /// which `ArticleFindTests` pins against this method.
    static func make(blocks: [Block], baseSize: CGFloat,
                     design: PlatformFontDescriptor.SystemDesign, color: PlatformColor = .yanaLabel,
                     highlights: (Int) -> [FindHighlightRange] = { _ in [] }) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let isLast = i == blocks.count - 1
            let runs: [InlineRun]
            let size: CGFloat
            let weight: PlatformFont.Weight
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
            FindHighlightStyle.apply(highlights(i), to: result, offset: start)
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

    /// Body-relative heading point size. Shared by both standalone headings (`BlockNodeView`,
    /// nested inside a list/blockquote) and coalesced top-level headings (`StaticTextRun`) so the
    /// fast-Text-to-SelectableText swap never reflows.
    static func headingSize(_ baseSize: CGFloat, _ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize * 1.5
        case 2: return baseSize * 1.3
        case 3: return baseSize * 1.15
        default: return baseSize * 1.05
        }
    }

    private static func appendRuns(_ runs: [InlineRun], into result: NSMutableAttributedString,
                                   baseSize: CGFloat, weight: PlatformFont.Weight,
                                   design: PlatformFontDescriptor.SystemDesign, color: PlatformColor) {
        let baseDescriptor = systemDescriptor(size: baseSize, weight: weight, design: design)
        for run in runs {
            var traits = baseDescriptor.symbolicTraits
            if run.styles.contains(.bold) { traits.insert(.yanaBold) }
            if run.styles.contains(.italic) { traits.insert(.yanaItalic) }
            var descriptor = applying(traits, to: baseDescriptor)
            // Inline `code` pins a monospaced face at the same size, like the SwiftUI `.code` intent.
            if run.styles.contains(.code) {
                descriptor = descriptor.withDesign(.monospaced) ?? descriptor
            }
            let font = font(descriptor: descriptor, size: baseSize)
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

    static func make(string: String, size: CGFloat, weight: PlatformFont.Weight = .regular,
                     design: PlatformFontDescriptor.SystemDesign, color: PlatformColor = .yanaLabel,
                     highlights: [FindHighlightRange] = []) -> NSAttributedString {
        let font = font(descriptor: systemDescriptor(size: size, weight: weight, design: design), size: size)
        let result = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        FindHighlightStyle.apply(highlights, to: result)
        return result
    }

    private static func systemDescriptor(size: CGFloat, weight: PlatformFont.Weight,
                                         design: PlatformFontDescriptor.SystemDesign) -> PlatformFontDescriptor {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
    }

    /// `withSymbolicTraits` returns an optional on UIKit (the trait combination may not resolve to a
    /// real face) and a non-optional on AppKit, so the `?? base` fallback the UIKit call site needs
    /// is a warning on macOS. Same intent, two spellings, resolved once here.
    private static func applying(_ traits: PlatformFontDescriptor.SymbolicTraits,
                                 to descriptor: PlatformFontDescriptor) -> PlatformFontDescriptor {
        #if os(macOS)
        descriptor.withSymbolicTraits(traits)
        #else
        descriptor.withSymbolicTraits(traits) ?? descriptor
        #endif
    }

    /// `UIFont(descriptor:size:)` is non-failable; `NSFont(descriptor:size:)` is failable (AppKit
    /// answers `nil` when the descriptor names no installed face). The fallback is the plain system
    /// font at the same size, which is what UIKit silently substitutes anyway — so both platforms
    /// end up with "the requested face, or the system face at the right size", never a crash.
    private static func font(descriptor: PlatformFontDescriptor, size: CGFloat) -> PlatformFont {
        #if os(macOS)
        NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        #else
        UIFont(descriptor: descriptor, size: size)
        #endif
    }
}

extension ArticleFont {
    /// AppKit/UIKit equivalent of `design`, for text baked into a `SelectableText` (which the
    /// SwiftUI `.fontDesign` modifier does not reach).
    var platformDesign: PlatformFontDescriptor.SystemDesign {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}
