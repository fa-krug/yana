import Foundation
import SwiftData

/// Content-addressed image blob, synced via SwiftData+CloudKit. The bytes travel as a CKAsset
/// (external storage). `ImageStore` keeps a disk cache in front of this; `ImageSync` bridges the two.
/// `contentHash` matches the `yana-img://<hash>` refs embedded in article blocks and `Feed.logoHash`.
@Model
final class StoredImage {
    var contentHash: String = ""
    @Attribute(.externalStorage) var data: Data = Data()
    /// File extension recorded so a materialized cache file gets the right name (e.g. "jpg", "png").
    var ext: String = "img"
    var createdAt: Date = Date.now

    init(contentHash: String, data: Data, ext: String) {
        self.contentHash = contentHash
        self.data = data
        self.ext = ext
        self.createdAt = .now
    }
}
