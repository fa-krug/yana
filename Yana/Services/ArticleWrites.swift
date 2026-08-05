import Foundation
import SwiftData

/// Centralizes the optimistic-local-write-then-PATCH pattern shared by starring and marking read:
/// flip the local flag and save immediately, then fire the PATCH; on failure, enqueue into
/// `PendingWriteQueue` instead of rolling back (see that type's doc comment for why). Silently
/// local-only when not paired -- `AuthenticatedClient.current()` returning `nil` means "nothing to
/// do," not an error, matching every other write path in this app.
@MainActor
enum ArticleWrites {
    static func toggleStar(_ article: Article, modelContext: ModelContext, settings: AppSettings = AppSettings()) {
        let newValue = !article.starred
        article.starred = newValue
        try? modelContext.save()
        guard let client = AuthenticatedClient.current(), let serverID = article.serverID else { return }
        Task {
            do {
                try await ArticleActions(client: client).setStarred(newValue, articleServerID: serverID)
            } catch {
                PendingWriteQueue.enqueue(PendingWrite(articleServerID: serverID, field: .starred(newValue)), settings: settings)
            }
        }
    }

    /// No-ops if already read -- both to avoid a redundant PATCH on every subsequent swipe past an
    /// already-read article, and because a page can be "displayed" more than once in a session
    /// (e.g. swiping back over it).
    static func markRead(_ article: Article, modelContext: ModelContext, settings: AppSettings = AppSettings()) {
        guard !article.read else { return }
        article.setRead(true)
        try? modelContext.save()
        guard let client = AuthenticatedClient.current(), let serverID = article.serverID else { return }
        Task {
            do {
                try await ArticleActions(client: client).setRead(true, articleServerID: serverID)
            } catch {
                PendingWriteQueue.enqueue(PendingWrite(articleServerID: serverID, field: .read(true)), settings: settings)
            }
        }
    }
}
