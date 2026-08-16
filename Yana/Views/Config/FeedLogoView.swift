import SwiftUI
import UIKit

/// A small rounded feed logo, with a neutral placeholder when no logo is cached yet.
///
/// Feed logos go through the same decoded-bitmap cache as article images (`ReaderImageCache`:
/// off-main decode, downsampling, byte-limited `NSCache`) instead of a per-row main-thread
/// `Data(contentsOf:)` + `UIImage(data:)` with no cache (audit P8).
struct FeedLogoView: View {
    let hash: String?
    var size: CGFloat = 28

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "globe")
                    .resizable().scaledToFit().padding(4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text("Feed logo"))
        .task(id: hash) {
            guard let hash else { image = nil; return }
            // Sync eagerly mirrors logos, but cover the cache-miss case (fresh install
            // mid-sync) exactly like before.
            if let client = AuthenticatedClient.current() {
                _ = await ImageStore.shared.fetchIfNeeded(hash: hash, client: client)
            }
            image = await ReaderImageCache.shared.image(for: "yana-img://\(hash)")
        }
    }
}
