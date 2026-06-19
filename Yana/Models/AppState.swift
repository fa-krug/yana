import Foundation

@MainActor
@Observable
final class AppState {
    /// Index into the (filtered) timeline.
    var currentIndex: Int = 0
    var isUpdating = false
    var errorMessage: String?
    var showSettings = false
    var showFilter = false
    /// When non-nil, the reader presents `FeedEditorView` for this feed as a sheet.
    var feedToEdit: Feed?
}
