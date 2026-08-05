import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Tag")
struct TagTests {
    // `feedTagsAreSnapshotIntoArticleTags` (last remaining test in this suite) removed: it asserted
    // the on-device import-time snapshot from `Feed.tags` (a `[Tag]?` relationship) onto
    // `Article.tags`. `Feed` no longer carries a live `[Tag]` relationship at all (replaced by
    // `tagIDs: [Int]`, a plain server-mirrored id list -- see Task 7 brief), so there is nothing left
    // to snapshot from at this layer; the concept the test verified no longer exists here. Nothing of
    // value is lost: `Article.tags` itself is untouched and still exercised elsewhere (e.g.
    // `LibraryFixture`), and how tag membership reaches an `Article` going forward is `SyncWriter`'s
    // concern (Task 9), not `Tag`'s.
}
