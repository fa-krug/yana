import Foundation

@MainActor
@Observable
final class AppState {
    /// Index into the (filtered) timeline.
    var currentIndex: Int = 0
    var isUpdating = false
    var showWelcome = false
    var showSettings = false
    var showFilter = false
    var showArticleList = false
}
