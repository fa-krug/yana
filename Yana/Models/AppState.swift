import Foundation

@MainActor
@Observable
final class AppState {
    /// What the reader is currently showing.
    enum Scope: Equatable {
        case allUnread
        case starred
    }

    var scope: Scope = .allUnread
    var currentIndex: Int = 0
    var isUpdating = false
    var errorMessage: String?
    var showSettings = false
}
