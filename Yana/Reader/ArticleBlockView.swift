import SwiftUI
import UIKit

/// Value snapshot of an article for native rendering. Decoupled from the `@Model` `Article` so the
/// SwiftUI view renders pure values (no model access mid-layout).
struct ReaderArticle: Equatable {
    let title: String
    let feedName: String
    let author: String
    let date: Date
    let logoHash: String?
    let url: String
    let summary: String
    let blocks: [Block]

    @MainActor
    init(_ article: Article) {
        title = article.title
        feedName = article.feed?.name ?? ""
        author = article.author
        date = article.createdAt
        logoHash = article.feed?.logoHash
        url = article.url
        summary = article.summary
        blocks = article.blocks
    }
}

/// Native SwiftUI renderer for an article's `[Block]` body — replaces the WebView + themed-HTML
/// reader page. Renders top-to-bottom in a scroll view: heading + dateline, the AI summary card
/// (after the lead image), then each block. Text is `AttributedString` so selection, Dynamic Type
/// and accessibility come for free; links and embeds open externally via `onOpenLink`.
struct ArticleBlockView: View {
    let article: ReaderArticle
    let textSize: ArticleTextSize
    var font: ArticleFont = .system
    var summaryPending: Bool = false
    var onOpenLink: (URL) -> Void = { _ in }
    /// Tapping a video embed plays it full-screen in-app rather than opening the website.
    var onPlayVideo: (Embed) -> Void = { _ in }
    var onRefresh: (() -> Void)?

    private var bodySize: CGFloat { CGFloat(textSize.pointSize) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(Array(bodyBlocks.enumerated()), id: \.offset) { _, block in
                    BlockNodeView(block: block, bodySize: bodySize,
                                  leadImageRef: leadImageRef, onOpenLink: onOpenLink,
                                  onPlayVideo: onPlayVideo)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fontDesign(font.design)   // applies the chosen typeface to all text (code blocks pin their own monospaced design)
            .textSelection(.enabled)
            .tint(.accentColor)   // colors tappable links in the rendered AttributedString
        }
        .environment(\.openURL, OpenURLAction { url in
            onOpenLink(url)
            return .handled
        })
        .modifier(RefreshableIfAvailable(onRefresh: onRefresh))
        .modifier(LeadImageReveal(leadImageRef: leadImageRef))
    }

    // MARK: - Header / summary / lead image ordering

    /// The blocks are rendered as-is, except the AI summary card is injected after a leading image
    /// (the lead media) so it sits between the image and the body — matching the prior reader.
    private var bodyBlocks: [Block] { article.blocks }

    /// Ref of the lead image (when the first block is an image), so `BlockNodeView` can skip it in
    /// the body — the header renders it once, between the title and the summary.
    private var leadImageRef: String? {
        if case let .image(ref, _)? = bodyBlocks.first { return ref }
        return nil
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !article.title.isEmpty {
                Text(article.title)
                    .font(.system(size: bodySize * 1.5, weight: .bold))
                    // Long headlines (especially German compounds like "niedersächsischen") used to
                    // balloon to 4+ huge lines. Cap the line count and let the font scale down to fit
                    // so a long title shrinks gracefully instead of dominating the screen; tightening
                    // lets words pack closer rather than stranding short words on their own line.
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            dateline
            // Lead image (if the first block is an image) renders before the summary.
            if case let .image(ref, caption)? = bodyBlocks.first {
                BlockImageView(ref: ref, caption: caption, bodySize: bodySize)
            }
            summaryCard
        }
    }

    @ViewBuilder private var dateline: some View {
        HStack(spacing: 8) {
            FeedLogoView(hash: article.logoHash)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                if !article.feedName.isEmpty {
                    Text(article.feedName)
                        .font(.system(size: bodySize * 0.8, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                HStack(spacing: 6) {
                    if !article.author.isEmpty {
                        Text(article.author)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(article.date, style: .date)
                }
                .font(.system(size: bodySize * 0.75))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var summaryCard: some View {
        let trimmed = article.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            summaryContainer { Text(trimmed).font(.system(size: bodySize)) }
        } else if summaryPending {
            summaryContainer {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: i == 2 ? 160 : nil, height: 12)
                            .frame(maxWidth: i == 2 ? nil : .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder private func summaryContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary")
                .font(.system(size: bodySize * 0.7, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

}

/// Renders a single `Block`, recursing into list items and blockquote contents. This is a nominal
/// `View` (not a `@ViewBuilder` function) on purpose: a `some View`-returning function that calls
/// itself yields "opaque return type defined in terms of itself". Recursing through a named type
/// breaks that cycle — `body`'s opaque type only ever references `BlockNodeView` (nominal), never
/// its own opaque type. The lead image is skipped here (the header renders it once).
private struct BlockNodeView: View {
    let block: Block
    let bodySize: CGFloat
    let leadImageRef: String?
    let onOpenLink: (URL) -> Void
    let onPlayVideo: (Embed) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch block {
        case .paragraph(let runs):
            Text(attributedString(from: runs))
                .font(.system(size: bodySize))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let runs):
            Text(attributedString(from: runs))
                .font(.system(size: headingSize(level), weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        case .list(let ordered, let items):
            listView(ordered: ordered, items: items)
        case .blockquote(let inner):
            blockquoteView(inner)
        case .image(let ref, let caption):
            // The lead image is rendered in the header; skip it here to avoid a duplicate.
            if ref != leadImageRef {
                BlockImageView(ref: ref, caption: caption, bodySize: bodySize)
            }
        case .embed(let embed):
            EmbedCardView(embed: embed, baseSize: bodySize, onOpen: openExternal, onPlayVideo: onPlayVideo)
        case .codeBlock(let text, _):
            Text(text)
                .font(.system(size: bodySize * 0.9, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider().padding(.vertical, 4)
        }
    }

    @ViewBuilder private func listView(ordered: Bool, items: [[Block]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, itemBlocks in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: bodySize))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(itemBlocks.enumerated()), id: \.offset) { _, b in
                            BlockNodeView(block: b, bodySize: bodySize,
                                          leadImageRef: leadImageRef, onOpenLink: onOpenLink,
                                          onPlayVideo: onPlayVideo)
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder private func blockquoteView(_ inner: [Block]) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inner.enumerated()), id: \.offset) { _, b in
                    BlockNodeView(block: b, bodySize: bodySize,
                                  leadImageRef: leadImageRef, onOpenLink: onOpenLink,
                                  onPlayVideo: onPlayVideo)
                }
            }
            .padding(.leading, 12)
            // `.secondary` is too dim to read comfortably against a dark background, so lift
            // blockquote text (e.g. Reddit comments) toward primary in dark mode.
            .foregroundStyle(colorScheme == .dark ? Color.primary.opacity(0.82) : Color.secondary)
        }
    }

    private func openExternal(_ urlString: String) {
        if let url = URL(string: urlString) { onOpenLink(url) }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return bodySize * 1.5
        case 2: return bodySize * 1.3
        case 3: return bodySize * 1.15
        default: return bodySize * 1.05
        }
    }
}

/// An image block: the image scaled to fit, with an optional caption. Shared by the header (lead
/// image) and `BlockNodeView` so there's one image impl.
private struct BlockImageView: View {
    let ref: String
    let caption: [InlineRun]
    let bodySize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReaderImageView(ref: ref)
            let captionRuns = caption.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !captionRuns.isEmpty {
                Text(attributedString(from: captionRuns))
                    .font(.system(size: bodySize * 0.8))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Build an `AttributedString` from inline runs using only Foundation-scope attributes
/// (`inlinePresentationIntent` + `.link`) so it stays unambiguous with both SwiftUI and UIKit
/// attribute scopes in view. Bold/italic/code/strikethrough relayer the surrounding `Text`'s base
/// font; links carry a `.link` so the `openURL` override routes the tap externally (tinted by the
/// view's `.tint`).
private func attributedString(from runs: [InlineRun]) -> AttributedString {
    var result = AttributedString()
    for run in runs {
        var piece = AttributedString(run.text)

        var intent: InlinePresentationIntent = []
        if run.styles.contains(.bold) { intent.insert(.stronglyEmphasized) }
        if run.styles.contains(.italic) { intent.insert(.emphasized) }
        if run.styles.contains(.code) { intent.insert(.code) }
        if run.styles.contains(.strikethrough) { intent.insert(.strikethrough) }
        if !intent.isEmpty { piece.inlinePresentationIntent = intent }

        if let link = run.link, let url = URL(string: link) {
            piece.link = url
        }
        result += piece
    }
    return result
}

/// Loads a `yana-img://<hash>` (or remote URL fallback) image and renders it scaled to fit. Resolves
/// against `ReaderImageCache`: if the image is already decoded (a revisited page, or a neighbor the
/// pager preloaded ahead of the swipe) it is taken synchronously at build time so the image is on
/// screen from the first frame — no empty placeholder, no pop-in. Otherwise it loads off the main
/// actor and fills in.
private struct ReaderImageView: View {
    let ref: String
    @State private var image: UIImage?

    init(ref: String) {
        self.ref = ref
        // Seed from the cache synchronously so an already-decoded image renders on the first frame
        // (the common case for prewarmed neighbors and revisited pages) instead of popping in.
        _image = State(initialValue: ReaderImageCache.shared.cached(ref))
    }

    var body: some View {
        Group {
            if let image {
                content(for: image)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: ref) {
            if image == nil { image = await ReaderImageCache.shared.image(for: ref) }
        }
    }

    /// Animated images (GIFs) play in a `UIImageView`-backed view — SwiftUI's `Image` shows only the
    /// first frame. Still images use the plain resizable `Image`.
    @ViewBuilder private func content(for image: UIImage) -> some View {
        if image.images != nil, image.size.width > 0, image.size.height > 0 {
            AnimatedImageView(image: image)
                .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        }
    }
}

/// Plays an animated `UIImage` (a GIF decoded into frames) — a `UIImageView` auto-animates such an
/// image, whereas SwiftUI's `Image` renders only the first frame.
private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        // Let SwiftUI's frame/aspectRatio drive the size rather than the image's intrinsic size.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
    }
}

/// A tappable embed card: a 16:9 poster with a play glyph for videos, or a text card for tweets.
/// Tapping a video poster plays it full-screen in-app (`onPlayVideo`); a tweet card — and any video
/// we can't play in place — opens its external URL via the reader's link policy (`onOpen`).
private struct EmbedCardView: View {
    let embed: Embed
    let baseSize: CGFloat
    let onOpen: (String) -> Void
    let onPlayVideo: (Embed) -> Void

    /// True for video embeds we can play inline (their player URL resolves); a tweet, or a video
    /// whose id can't be parsed, stays a link-out.
    private var isPlayableVideo: Bool {
        ReaderVideoPlayerViewController.playerURL(for: embed) != nil
    }

    var body: some View {
        Button {
            if isPlayableVideo {
                onPlayVideo(embed)
            } else {
                onOpen(embed.externalURL)
            }
        } label: {
            switch embed.provider {
            case .tweet:
                textCard
            default:
                posterCard
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var posterCard: some View {
        ZStack {
            if let ref = embed.thumbnailRef {
                ReaderImageView(ref: ref)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.white, .black.opacity(0.5))
                .accessibilityLabel(Text("Play video"))
        }
    }

    @ViewBuilder private var textCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "bird")
                .font(.system(size: baseSize * 1.3))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(embed.title ?? embed.externalURL)
                    .font(.system(size: baseSize * 0.9))
                    .lineLimit(4)
                    .foregroundStyle(.primary)
                Text("View post")
                    .font(.system(size: baseSize * 0.8, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Holds the page invisible (but fully laid out) until its lead image is decoded, then fades the
/// whole article in at once — so the reader never shows the body text first and visibly jumps when
/// the header image pops in afterwards (the "flash"). When the lead image is already in
/// `ReaderImageCache` — the common case, since the pager prewarms neighbors' and the displayed
/// page's lead images — the page starts visible, so there is no fade and no blank frame. Pages with
/// no lead image are visible from the first frame.
private struct LeadImageReveal: ViewModifier {
    let leadImageRef: String?
    @State private var ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(leadImageRef: String?) {
        self.leadImageRef = leadImageRef
        // Seed synchronously from the cache so an already-decoded lead image (prewarmed/revisited)
        // shows on the first frame with no fade — only a cold image waits for the reveal.
        _ready = State(initialValue: leadImageRef == nil
            || ReaderImageCache.shared.cached(leadImageRef!) != nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(ready ? 1 : 0)
            .animation(Motion.resolve(.easeIn(duration: 0.2), reduceMotion: reduceMotion), value: ready)
            .task(id: leadImageRef) {
                guard !ready, let leadImageRef else { return }
                _ = await ReaderImageCache.shared.image(for: leadImageRef)
                ready = true
            }
    }
}

/// Applies `.refreshable` only when a refresh handler is provided. `.refreshable` needs an async
/// body; the pager's refresh is fire-and-forget (it starts a tracked task), so we await a brief
/// tick to let the pull gesture settle before the spinner dismisses.
private struct RefreshableIfAvailable: ViewModifier {
    let onRefresh: (() -> Void)?
    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable {
                onRefresh()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        } else {
            content
        }
    }
}
