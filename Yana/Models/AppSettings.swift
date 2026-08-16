import Foundation

enum AIMode: String, CaseIterable, Sendable, Identifiable {
    case server
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .server: String(localized: "Server")
        case .appleIntelligence: String(localized: "Apple Intelligence")
        }
    }
}

/// Non-secret user preferences, backed by UserDefaults. Secrets live in `KeychainService`.
@MainActor
@Observable
final class AppSettings {
    /// Posted when `articleTextSize` changes so the reader can re-render live (no app restart).
    static let articleTextSizeDidChange = Notification.Name("YanaArticleTextSizeDidChange")
    /// Posted when `articleFont` changes so the reader can re-render live (no app restart).
    static let articleFontDidChange = Notification.Name("YanaArticleFontDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.updateInterval: UpdateInterval.min60.rawValue,
            Key.aiMode: AIMode.server.rawValue,
            Key.includeUntagged: true,
            Key.articleTextSize: ArticleTextSize.medium.rawValue,
            Key.articleFont: ArticleFont.system.rawValue,
        ])
    }

    /// Reads a `UserDefaults` integer that distinguishes "unset" from the value `0`, unlike
    /// `UserDefaults.integer(forKey:)`'s bare `0` default. Shared by the three optional-`Int`
    /// settings below (`timelineAnchorServerID`, `pendingRemoteReadingPosition`,
    /// `pendingReadingPositionPush`), which otherwise repeated this exact nil-check.
    private func optionalInt(forKey key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    /// Writes an optional `Int` as either the value itself or a removed key (so a later
    /// `optionalInt(forKey:)` reads back `nil`, not `0`).
    private func setOptionalInt(_ value: Int?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private enum Key {
        static let updateInterval = "settings.updateInterval"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let showUnreadBadge = "settings.showUnreadBadge"
        // AI
        static let aiMode = "settings.aiMode"
        static let serverBaseURL = "settings.serverBaseURL"
        // Sync
        static let syncCursor = "settings.syncCursor"
        static let pendingWrites = "settings.pendingWrites"
        // Timeline filter
        static let disabledTagNames = "settings.disabledTagNames"
        static let includeUntagged = "settings.includeUntagged"
        static let disabledFeedNames = "settings.disabledFeedNames"
        static let starredOnly = "settings.starredOnly"
        // Timeline position
        static let timelineAnchorIdentifier = "settings.timelineAnchorIdentifier"
        static let timelineAnchorServerID = "settings.timelineAnchorServerID"
        // Reading position sync
        static let readingPositionUpdatedAt = "settings.readingPositionUpdatedAt"
        static let pendingRemoteReadingPosition = "settings.pendingRemoteReadingPosition"
        static let pendingReadingPositionPush = "settings.pendingReadingPositionPush"
        // Reader
        static let articleTextSize = "settings.articleTextSize"
        static let articleFont = "settings.articleFont"
        static let preferredVoiceIdentifier = "settings.preferredVoiceIdentifier"
        static let useSystemBrowser = "settings.useSystemBrowser"
        static let articleFullscreenEnabled = "settings.articleFullscreenEnabled"
        static let hasSeenFullscreenHint = "settings.hasSeenFullscreenHint"
        // Onboarding
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        // Initial sync
        static let hasCompletedInitialSync = "settings.hasCompletedInitialSync"
        // Image prune gate
        static let imagePruneNeeded = "settings.imagePruneNeeded"
        // Demo mode (skipped server pairing)
        static let hasSkippedServerPairing = "settings.hasSkippedServerPairing"
        static let hasDismissedDemoBanner = "settings.hasDismissedDemoBanner"
        // Server migration notice
        static let hasEvaluatedServerMigrationEligibility = "settings.hasEvaluatedServerMigrationEligibility"
        static let isPreServerMigrationUser = "settings.isPreServerMigrationUser"
        static let hasDismissedServerMigrationNotice = "settings.hasDismissedServerMigrationNotice"
        // Mac window layout (device-local, never synced)
        static let macSidebarWidth = "settings.macSidebarWidth"
    }

    /// The Mac window's remembered sidebar column width (device-local, never synced — window layout
    /// is per-device). 0 means "unset → use the ideal default".
    var macSidebarWidth: Double {
        get { access(keyPath: \.macSidebarWidth); return defaults.double(forKey: Key.macSidebarWidth) }
        set { withMutation(keyPath: \.macSidebarWidth) { defaults.set(newValue, forKey: Key.macSidebarWidth) } }
    }

    /// Per-device background aggregation cadence. Device-local — never synced. `.off` = pure mirror.
    var updateInterval: UpdateInterval {
        get {
            access(keyPath: \.updateInterval)
            guard let raw = defaults.string(forKey: Key.updateInterval),
                  let value = UpdateInterval(rawValue: raw) else { return .min60 }
            return value
        }
        set { withMutation(keyPath: \.updateInterval) { defaults.set(newValue.rawValue, forKey: Key.updateInterval) } }
    }

    var notificationsEnabled: Bool {
        get { access(keyPath: \.notificationsEnabled); return defaults.bool(forKey: Key.notificationsEnabled) }
        set { withMutation(keyPath: \.notificationsEnabled) { defaults.set(newValue, forKey: Key.notificationsEnabled) } }
    }
    /// Opt-in (default off) app-icon badge showing the unread count within the current timeline
    /// filter. See `UnreadBadgeUpdater`.
    var showUnreadBadge: Bool {
        get { access(keyPath: \.showUnreadBadge); return defaults.bool(forKey: Key.showUnreadBadge) }
        set { withMutation(keyPath: \.showUnreadBadge) { defaults.set(newValue, forKey: Key.showUnreadBadge) } }
    }

    // MARK: AI
    /// Which AI path produces the reader's summary block. `.server` calls
    /// `POST /api/v1/ai/prompt` against whatever provider the user configured server-side;
    /// `.appleIntelligence` runs entirely on-device. Device-local — never synced (mirrors
    /// `updateInterval`'s reasoning: this is a per-device capability choice, not a library setting).
    var aiMode: AIMode {
        get {
            access(keyPath: \.aiMode)
            guard let raw = defaults.string(forKey: Key.aiMode), let mode = AIMode(rawValue: raw) else { return .server }
            return mode
        }
        set { withMutation(keyPath: \.aiMode) { defaults.set(newValue.rawValue, forKey: Key.aiMode) } }
    }

    /// The paired yana-server's base URL (self-hosted software — there is no fixed host).
    /// Entered during onboarding's server-configuration step, editable later in Settings.
    var serverBaseURL: String {
        get { access(keyPath: \.serverBaseURL); return defaults.string(forKey: Key.serverBaseURL) ?? "" }
        set { withMutation(keyPath: \.serverBaseURL) { defaults.set(newValue, forKey: Key.serverBaseURL) } }
    }

    /// Opaque cursor from the last successful `/api/v1/articles/sync` call. `nil` forces a full
    /// resync from scratch. Device-local network state — never synced.
    var syncCursor: String? {
        get { access(keyPath: \.syncCursor); return defaults.string(forKey: Key.syncCursor) }
        set { withMutation(keyPath: \.syncCursor) { defaults.set(newValue, forKey: Key.syncCursor) } }
    }

    /// Not-yet-acknowledged star/read writes, retried opportunistically on the next sync. See
    /// `PendingWriteQueue`. Device-local network state -- never synced.
    var pendingWrites: [PendingWrite] {
        get {
            access(keyPath: \.pendingWrites)
            guard let data = defaults.data(forKey: Key.pendingWrites),
                  let decoded = try? JSONDecoder().decode([PendingWrite].self, from: data) else { return [] }
            return decoded
        }
        set {
            withMutation(keyPath: \.pendingWrites) {
                let data = try? JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Key.pendingWrites)
            }
        }
    }

    // MARK: Timeline filter
    /// Names of tags currently toggled OFF in the filter. Empty = all active.
    var disabledTagNames: Set<String> {
        get { access(keyPath: \.disabledTagNames); return Set(defaults.stringArray(forKey: Key.disabledTagNames) ?? []) }
        set { withMutation(keyPath: \.disabledTagNames) { defaults.set(Array(newValue), forKey: Key.disabledTagNames) } }
    }
    var includeUntagged: Bool {
        get { access(keyPath: \.includeUntagged); return defaults.bool(forKey: Key.includeUntagged) }
        set { withMutation(keyPath: \.includeUntagged) { defaults.set(newValue, forKey: Key.includeUntagged) } }
    }
    /// Names of feeds currently toggled OFF in the filter. Empty = all active.
    var disabledFeedNames: Set<String> {
        get { access(keyPath: \.disabledFeedNames); return Set(defaults.stringArray(forKey: Key.disabledFeedNames) ?? []) }
        set { withMutation(keyPath: \.disabledFeedNames) { defaults.set(Array(newValue), forKey: Key.disabledFeedNames) } }
    }
    /// True when the timeline filter would hide some articles (a tag or feed is off, or untagged
    /// articles are excluded). Drives the reader's filter-button active state.
    var isTimelineFilterActive: Bool {
        !disabledTagNames.isEmpty || !includeUntagged || !disabledFeedNames.isEmpty || starredOnly
    }
    /// Timeline quick-filter: show only starred articles. Replaces the old built-in "Starred" tag
    /// row now that starring is a plain boolean, not tag membership.
    var starredOnly: Bool {
        get { access(keyPath: \.starredOnly); return defaults.bool(forKey: Key.starredOnly) }
        set { withMutation(keyPath: \.starredOnly) { defaults.set(newValue, forKey: Key.starredOnly) } }
    }

    // MARK: Reader
    var articleTextSize: ArticleTextSize {
        get { access(keyPath: \.articleTextSize); return ArticleTextSize(rawValue: defaults.integer(forKey: Key.articleTextSize)) ?? .medium }
        set {
            let changed = newValue != articleTextSize
            withMutation(keyPath: \.articleTextSize) { defaults.set(newValue.rawValue, forKey: Key.articleTextSize) }
            if changed { NotificationCenter.default.post(name: Self.articleTextSizeDidChange, object: self) }
        }
    }
    var articleFont: ArticleFont {
        get { access(keyPath: \.articleFont); return ArticleFont(rawValue: defaults.integer(forKey: Key.articleFont)) ?? .system }
        set {
            let changed = newValue != articleFont
            withMutation(keyPath: \.articleFont) { defaults.set(newValue.rawValue, forKey: Key.articleFont) }
            if changed { NotificationCenter.default.post(name: Self.articleFontDidChange, object: self) }
        }
    }
    /// Identifier of the `AVSpeechSynthesisVoice` the user picked for read-aloud, or `nil` to let
    /// the reader pick automatically by matching the article's language.
    var preferredVoiceIdentifier: String? {
        get { access(keyPath: \.preferredVoiceIdentifier); return defaults.string(forKey: Key.preferredVoiceIdentifier) }
        set { withMutation(keyPath: \.preferredVoiceIdentifier) { defaults.set(newValue, forKey: Key.preferredVoiceIdentifier) } }
    }
    var useSystemBrowser: Bool {
        get { access(keyPath: \.useSystemBrowser); return defaults.bool(forKey: Key.useSystemBrowser) }
        set { withMutation(keyPath: \.useSystemBrowser) { defaults.set(newValue, forKey: Key.useSystemBrowser) } }
    }
    var articleFullscreenEnabled: Bool {
        get { access(keyPath: \.articleFullscreenEnabled); return defaults.bool(forKey: Key.articleFullscreenEnabled) }
        set { withMutation(keyPath: \.articleFullscreenEnabled) { defaults.set(newValue, forKey: Key.articleFullscreenEnabled) } }
    }
    /// One-time flag: whether the reader's tap-to-hide-bars hint has been shown.
    var hasSeenFullscreenHint: Bool {
        get { access(keyPath: \.hasSeenFullscreenHint); return defaults.bool(forKey: Key.hasSeenFullscreenHint) }
        set { withMutation(keyPath: \.hasSeenFullscreenHint) { defaults.set(newValue, forKey: Key.hasSeenFullscreenHint) } }
    }

    // MARK: Onboarding
    /// One-time flag: whether the first-launch welcome/onboarding screen has been dismissed.
    var hasCompletedOnboarding: Bool {
        get { access(keyPath: \.hasCompletedOnboarding); return defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { withMutation(keyPath: \.hasCompletedOnboarding) { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) } }
    }

    // MARK: Initial sync
    /// One-time flag: whether this device's very first sync (right after pairing) has ever
    /// completed and settled. Gates `InitialSyncGate` -- every sync after this one is a small
    /// incremental delta that never needs to block the reader.
    var hasCompletedInitialSync: Bool {
        get { access(keyPath: \.hasCompletedInitialSync); return defaults.bool(forKey: Key.hasCompletedInitialSync) }
        set { withMutation(keyPath: \.hasCompletedInitialSync) { defaults.set(newValue, forKey: Key.hasCompletedInitialSync) } }
    }

    // MARK: Image prune gate
    /// Set when a local swipe-to-delete (or similar client-only removal) could have orphaned an
    /// image -- `SyncWriter.referencedImageHashes()` decodes every article body, so
    /// `SyncEngine.performSync`'s `pruneOrphanedImages` pass only runs when this flag is set, a
    /// server-side removal landed, or a feed was pruned; otherwise every sync would pay that cost
    /// for nothing. Reset to `false` the moment a prune actually runs. Device-local -- never synced.
    var imagePruneNeeded: Bool {
        get { access(keyPath: \.imagePruneNeeded); return defaults.bool(forKey: Key.imagePruneNeeded) }
        set { withMutation(keyPath: \.imagePruneNeeded) { defaults.set(newValue, forKey: Key.imagePruneNeeded) } }
    }

    // MARK: Demo mode
    /// True when the user chose "Skip for now" on the onboarding server step instead of pairing.
    /// Cleared the moment a real pairing later succeeds (see `OnboardingServerPage`). Drives
    /// `WelcomeGate` (skip the re-pairing prompt) and `DemoModeBanner` (show the "you're viewing
    /// demo content" reminder).
    var hasSkippedServerPairing: Bool {
        get { access(keyPath: \.hasSkippedServerPairing); return defaults.bool(forKey: Key.hasSkippedServerPairing) }
        set { withMutation(keyPath: \.hasSkippedServerPairing) { defaults.set(newValue, forKey: Key.hasSkippedServerPairing) } }
    }
    /// Per-launch dismissal of `DemoModeBanner`. Not read at launch — `YanaApp` resets it to `false`
    /// on every launch — so the reminder reappears next time the app opens rather than being
    /// silenced forever.
    var hasDismissedDemoBanner: Bool {
        get { access(keyPath: \.hasDismissedDemoBanner); return defaults.bool(forKey: Key.hasDismissedDemoBanner) }
        set { withMutation(keyPath: \.hasDismissedDemoBanner) { defaults.set(newValue, forKey: Key.hasDismissedDemoBanner) } }
    }

    // MARK: Server Migration Notice
    /// One-time flag: whether this device's pre-server-migration eligibility has been evaluated.
    var hasEvaluatedServerMigrationEligibility: Bool {
        get { access(keyPath: \.hasEvaluatedServerMigrationEligibility); return defaults.bool(forKey: Key.hasEvaluatedServerMigrationEligibility) }
        set { withMutation(keyPath: \.hasEvaluatedServerMigrationEligibility) { defaults.set(newValue, forKey: Key.hasEvaluatedServerMigrationEligibility) } }
    }
    /// Whether this device had already completed onboarding before Yana required a server.
    var isPreServerMigrationUser: Bool {
        get { access(keyPath: \.isPreServerMigrationUser); return defaults.bool(forKey: Key.isPreServerMigrationUser) }
        set { withMutation(keyPath: \.isPreServerMigrationUser) { defaults.set(newValue, forKey: Key.isPreServerMigrationUser) } }
    }
    /// Whether the "Yana now requires a server" notice has been dismissed.
    var hasDismissedServerMigrationNotice: Bool {
        get { access(keyPath: \.hasDismissedServerMigrationNotice); return defaults.bool(forKey: Key.hasDismissedServerMigrationNotice) }
        set { withMutation(keyPath: \.hasDismissedServerMigrationNotice) { defaults.set(newValue, forKey: Key.hasDismissedServerMigrationNotice) } }
    }

    // MARK: Timeline position
    var timelineAnchorIdentifier: String? {
        get { access(keyPath: \.timelineAnchorIdentifier); return defaults.string(forKey: Key.timelineAnchorIdentifier) }
        set { withMutation(keyPath: \.timelineAnchorIdentifier) { defaults.set(newValue, forKey: Key.timelineAnchorIdentifier) } }
    }
    /// The anchored article's `serverID`, alongside `timelineAnchorIdentifier`. `identifier` is only
    /// a per-feed dedup key (two feeds can share a source URL), so every anchor-resolution lookup
    /// prefers this globally-unique id when it's present -- see `TimelinePageIndex.index`. `nil` for
    /// an anchor saved before this field existed, or for unsynced fixture data; those fall back to
    /// the identifier-only lookup.
    var timelineAnchorServerID: Int? {
        get { access(keyPath: \.timelineAnchorServerID); return optionalInt(forKey: Key.timelineAnchorServerID) }
        set { withMutation(keyPath: \.timelineAnchorServerID) { setOptionalInt(newValue, forKey: Key.timelineAnchorServerID) } }
    }

    // MARK: Reading position sync
    /// The most recent reading-position `updatedAt` this device knows about -- either its own
    /// push's server-stamped ack, or a value pulled from the server. `SyncEngine.syncReadingPosition`
    /// compares against this (last-writer-wins) so a stale pull can never regress a newer local
    /// push still in flight, and so this device doesn't re-apply a position it just pushed itself.
    /// Device-local bookkeeping -- not itself synced.
    var readingPositionUpdatedAt: Date? {
        get { access(keyPath: \.readingPositionUpdatedAt); return defaults.object(forKey: Key.readingPositionUpdatedAt) as? Date }
        set { withMutation(keyPath: \.readingPositionUpdatedAt) { defaults.set(newValue, forKey: Key.readingPositionUpdatedAt) } }
    }
    /// A reading position pulled from the server but not yet applied to the visible timeline --
    /// the server article id to jump to. Consumed exactly once, by the reader's next fresh session
    /// (`ReaderAnchorController`/`TimelineModel`'s `jumpToSyncedTimelinePosition`, called only from
    /// `applyTimeline`'s first-load branch) -- never applied mid-session, which would yank the user
    /// off the article they're actively reading. `nil` once consumed.
    var pendingRemoteReadingPosition: Int? {
        get { access(keyPath: \.pendingRemoteReadingPosition); return optionalInt(forKey: Key.pendingRemoteReadingPosition) }
        set { withMutation(keyPath: \.pendingRemoteReadingPosition) { setOptionalInt(newValue, forKey: Key.pendingRemoteReadingPosition) } }
    }
    /// A local reading-position push that failed (offline, or a real server error) and needs
    /// retry -- the server article id to (re)send. Retried opportunistically alongside
    /// `PendingWriteQueue`, see `ReadingPositionSync.flushPending`. Not folded into
    /// `PendingWriteQueue` itself: that queue's dedup key is per-article, but a reading-position
    /// push has no per-article multiplicity -- there is only ever one current position -- so a
    /// single field, always overwritten by the newest attempt, is simpler and correct.
    /// Device-local -- never synced.
    var pendingReadingPositionPush: Int? {
        get { access(keyPath: \.pendingReadingPositionPush); return optionalInt(forKey: Key.pendingReadingPositionPush) }
        set { withMutation(keyPath: \.pendingReadingPositionPush) { setOptionalInt(newValue, forKey: Key.pendingReadingPositionPush) } }
    }
}
