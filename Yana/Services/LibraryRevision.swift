import Foundation

/// Bumps a revision counter whenever CloudKit mirrors a remote change into the local store, so
/// SwiftUI `@Query`-backed views that don't otherwise react to it can force a re-fetch.
///
/// A CloudKit merge lands below SwiftData, through Core Data: it posts
/// `.NSPersistentStoreRemoteChange` and no `ModelContext.didSave`, so `@Query` is never
/// re-evaluated. `ArticleStore` works around this for the timeline with its own remote-change
/// observer plus incremental splicing (see `ArticleStore.swift`); this is the equivalent for the
/// smaller `@Query`-backed lists — Tags, Feeds, the Mac filter bar, the feed editor's tag picker —
/// where a full re-fetch on every bump is cheap enough that no splicing is worth building.
///
/// Consumers key a narrow subview's `.id(LibraryRevision.shared.token)` so recreating it re-runs
/// its `@Query`, without resetting state (search text, sheet presentation, in-flight edits) that
/// lives above that subview.
@MainActor
@Observable
final class LibraryRevision {
    /// The app-lifetime instance, observing the real `.default` `NotificationCenter`.
    static let shared = LibraryRevision()

    private(set) var token = 0

    private let center: NotificationCenter

    /// Coalesces a burst of remote-change notifications into a single bump. A large sync fires
    /// `.NSPersistentStoreRemoteChange` many times in quick succession — including, per
    /// `ArticleStoreIncrementalTests`, several times for a single *local* save on a `.automatic`
    /// store — so bumping on every notification would force every wired view to re-fetch (and
    /// SwiftUI to rebuild the recreated subviews) dozens of times a second. One rebuild per burst
    /// costs nothing here (these lists are small), while re-fetching on a local save that already
    /// applied its own SwiftUI update is merely redundant, not wrong. The interval matches
    /// `LibraryDedup`'s own remote-change coalescer.
    private let interval: Duration
    private var coalescer: TrailingCoalescer?
    private var observer: NSObjectProtocol?

    /// `center`/`interval` are injectable so tests can exercise the coalescing behavior against a
    /// private `NotificationCenter` (avoiding cross-test interference on the shared `.default`
    /// center) with a short interval, without touching `.shared`.
    init(center: NotificationCenter = .default, interval: Duration = .seconds(1.5)) {
        self.center = center
        self.interval = interval
    }

    /// Registers the `.NSPersistentStoreRemoteChange` observer. Idempotent; call once at launch.
    func startObserving() {
        guard observer == nil else { return }
        let coalescer = TrailingCoalescer(interval: interval) { [weak self] in
            self?.token += 1
        }
        self.coalescer = coalescer
        observer = center.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in coalescer.schedule() }
        }
    }

    isolated deinit {
        if let observer { center.removeObserver(observer) }
    }
}
