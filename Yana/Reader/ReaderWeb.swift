import Foundation

/// Stable values shared by the aggregation pipeline and the reader.
enum ReaderWeb {
    /// Origin baked into the `origin=` parameter of the video-embed facades `EmbedRewriter` builds.
    /// The native reader renders embeds as poster cards (no live iframe), but the facade markup
    /// still carries this so `BlockParser` can recognize and extract the embed; the host need only
    /// be consistent, not reachable.
    static let baseOrigin = "https://app.yana.local"

    /// Custom URL scheme used to reference locally cached images: `yana-img://<contentHash>`. The
    /// aggregation pipeline rewrites every `<img src>` to this, and the native reader resolves the
    /// hash to a file in `ImageStore` (no remote image URLs are ever rendered).
    static let imageScheme = "yana-img"
}
