import SwiftUI
import UIKit

/// Loads a cached logo image by content hash from an `ImageStore`. Returns nil for a nil/missing
/// hash or unreadable file. Pure async helper so it can be unit-tested without rendering.
enum FeedLogo {
    static func image(forHash hash: String?, in store: ImageStore = .shared) async -> UIImage? {
        guard let hash else { return nil }
        let url = await store.fileURL(forHash: hash)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

/// A small rounded feed logo, with a neutral placeholder when no logo is cached yet.
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
        .task(id: hash) { image = await FeedLogo.image(forHash: hash) }
    }
}
