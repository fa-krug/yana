import SwiftUI

/// Poster artwork for a video embed that has no thumbnail to show.
///
/// A poster is missing for two quite different reasons, and both used to land on the same flat
/// black 16:9 rectangle with a lone play glyph -- which reads as an image that failed to load
/// rather than as a deliberate "there is no preview for this."
///
/// 1. **There is no thumbnail anywhere.** A private, deleted or region-blocked YouTube video is
///    dropped from `img.youtube.com` (both `maxresdefault` and `hqdefault` answer 404 with a 120x90
///    grey placeholder), so `yana-server`'s `localizeThumbnail` stores an empty ref and
///    `encodeBlock` nulls it on the wire. No amount of retrying on this side will ever produce one.
/// 2. **The thumbnail hasn't landed yet.** The ref is real but its bytes aren't in `ImageStore` --
///    a first render before the sync-time prefetch caught up, or an image pruned since.
///
/// The artwork stands in for both: the same gradient card at the size the poster would have
/// occupied, so the layout doesn't jump when a late thumbnail does arrive over the top of it.
enum EmbedPoster {

    /// The ref to draw in the poster card, or `nil` when there is nothing to draw and
    /// `EmbedPosterPlaceholder` stands in for it. Treats an empty ref as absent: the wire nulls
    /// empties (`orNull` in the server's `encodeBlock`), but a locally-authored block -- a debug or
    /// screenshot fixture -- can still carry `""`, which resolves to no image just the same.
    static func posterRef(for embed: Embed) -> String? {
        guard let ref = embed.thumbnailRef, !ref.isEmpty else { return nil }
        return ref
    }

    static func needsPlaceholder(for embed: Embed) -> Bool { posterRef(for: embed) == nil }

    /// The watermark glyph for a provider. Deliberately generic shapes rather than brand marks --
    /// there is no licensed YouTube/Dailymotion symbol to draw, and inventing one is worse than a
    /// neutral one.
    static func glyph(for provider: Embed.Provider) -> String {
        switch provider {
        case .youtube, .dailymotion, .generic: "film.fill"
        case .video: "video.fill"
        case .tweet: "bubble.left.fill"
        }
    }
}

/// The 16:9 card `EmbedPoster` describes: a dark accent-tinted gradient with the provider's glyph
/// watermarked into the trailing corner, sized exactly as a real poster would be. Decorative --
/// the play glyph layered over it by `EmbedCardView` carries the accessibility label.
struct EmbedPosterPlaceholder: View {
    let provider: Embed.Provider

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [Color.accentColor.mix(with: .black, by: 0.55),
                         Color.accentColor.mix(with: .black, by: 0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: EmbedPoster.glyph(for: provider))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .padding(14)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
