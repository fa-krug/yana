import Foundation

enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case none
    case openai
    case anthropic
    case gemini
    case mistral
    case qwen
    case deepseek
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Disabled"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .mistral: "Mistral"
        case .qwen: "Qwen"
        case .deepseek: "DeepSeek"
        case .appleIntelligence: "Apple Intelligence"
        }
    }

    /// iOS-maintained current model lists (the server's choice lists are stale).
    /// Update these as providers ship new models.
    var models: [String] {
        switch self {
        case .none: []
        case .openai: ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o4-mini", "o3"]
        case .anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .mistral: ["mistral-small-latest", "mistral-large-latest", "mistral-medium-latest"]
        case .qwen: ["qwen3.5-flash", "qwen3.5-plus", "qwen3-max"]
        case .deepseek: ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .appleIntelligence: []
        }
    }

    var defaultModel: String { models.first ?? "" }

    /// Default chat-completions base URL for the OpenAI-compatible providers. For `.openai`
    /// the user-overridable `AppSettings.openaiAPIURL` takes precedence (resolved by callers);
    /// the other three use these fixed bases. Empty for providers that don't use this path.
    var baseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .qwen: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .none, .anthropic, .gemini, .appleIntelligence: ""
        }
    }

    /// Keychain item holding this provider's API key. `nil` for providers that need no key
    /// (`.none`, on-device `.appleIntelligence`).
    var apiKeyItem: KeychainService.APIKeyItem? {
        switch self {
        case .none, .appleIntelligence: return nil
        case .openai: return .openaiAPIKey
        case .anthropic: return .anthropicAPIKey
        case .gemini: return .geminiAPIKey
        case .mistral: return .mistralAPIKey
        case .qwen: return .qwenAPIKey
        case .deepseek: return .deepseekAPIKey
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
    /// Posted when the synced timeline anchor identifier changes (a synced pull applying a new
    /// `timelineAnchorUID`) so the reader can jump to that exact article. Cross-instance safe:
    /// `ConfigSyncService` and the reader hold separate `AppSettings` instances but share this
    /// global notification.
    static let timelinePositionDidChange = Notification.Name("YanaTimelinePositionDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.retentionDays: 30,
            Key.backgroundInterval: 3600.0,
            Key.redditUserAgent: "Yana/1.0",
            Key.openaiAPIURL: "https://api.openai.com/v1",
            Key.openaiModel: "gpt-4o-mini",
            Key.anthropicModel: "claude-haiku-4-5-20251001",
            Key.geminiModel: "gemini-2.5-flash",
            Key.mistralModel: "mistral-small-latest",
            Key.qwenModel: "qwen3.5-flash",
            Key.deepseekModel: "deepseek-v4-flash",
            Key.aiTemperature: 0.3,
            Key.aiMaxTokens: 2000,
            Key.aiMaxPromptLength: 500,
            Key.aiDefaultDailyLimit: 200,
            Key.aiDefaultMonthlyLimit: 2000,
            Key.aiRequestTimeout: 120,
            Key.aiMaxRetries: 3,
            Key.aiRetryDelay: 2,
            Key.aiRequestDelay: 2,
            Key.includeUntagged: true,
            Key.articleTextSize: ArticleTextSize.medium.rawValue,
            Key.articleFont: ArticleFont.system.rawValue,
        ])
    }

    private enum Key {
        static let activeAIProvider = "settings.activeAIProvider"
        static let retentionDays = "settings.retentionDays"
        static let backgroundInterval = "settings.backgroundInterval"
        // Sources
        static let redditEnabled = "settings.redditEnabled"
        static let redditUserAgent = "settings.redditUserAgent"
        static let youtubeEnabled = "settings.youtubeEnabled"
        static let notificationsEnabled = "settings.notificationsEnabled"
        // Providers
        static let openaiAPIURL = "settings.openaiAPIURL"
        static let openaiModel = "settings.openaiModel"
        static let anthropicModel = "settings.anthropicModel"
        static let geminiModel = "settings.geminiModel"
        static let mistralModel = "settings.mistralModel"
        static let qwenModel = "settings.qwenModel"
        static let deepseekModel = "settings.deepseekModel"
        // AI knobs
        static let aiTemperature = "settings.aiTemperature"
        static let aiMaxTokens = "settings.aiMaxTokens"
        static let aiMaxPromptLength = "settings.aiMaxPromptLength"
        static let aiDefaultDailyLimit = "settings.aiDefaultDailyLimit"
        static let aiDefaultMonthlyLimit = "settings.aiDefaultMonthlyLimit"
        static let aiRequestTimeout = "settings.aiRequestTimeout"
        static let aiMaxRetries = "settings.aiMaxRetries"
        static let aiRetryDelay = "settings.aiRetryDelay"
        static let aiRequestDelay = "settings.aiRequestDelay"
        // Timeline filter
        static let disabledTagNames = "settings.disabledTagNames"
        static let includeUntagged = "settings.includeUntagged"
        static let disabledFeedNames = "settings.disabledFeedNames"
        // Timeline position
        static let timelineAnchorIdentifier = "settings.timelineAnchorIdentifier"
        static let timelineAnchorSyncUID = "settings.timelineAnchorSyncUID"
        // Reader
        static let articleTextSize = "settings.articleTextSize"
        static let articleFont = "settings.articleFont"
        static let preferredVoiceIdentifier = "settings.preferredVoiceIdentifier"
        static let useSystemBrowser = "settings.useSystemBrowser"
        static let articleFullscreenEnabled = "settings.articleFullscreenEnabled"
        static let hasSeenFullscreenHint = "settings.hasSeenFullscreenHint"
        // Onboarding
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        // iCloud sync (device-local, never synced)
        static let iCloudSyncEnabled = "settings.iCloudSyncEnabled"
        static let isPassiveDevice = "settings.isPassiveDevice"
    }

    // MARK: iCloud Sync

    /// Master opt-in toggle for iCloud sync. Device-local — never included in the synced payload.
    var iCloudSyncEnabled: Bool {
        get { access(keyPath: \.iCloudSyncEnabled); return defaults.bool(forKey: Key.iCloudSyncEnabled) }
        set { withMutation(keyPath: \.iCloudSyncEnabled) { defaults.set(newValue, forKey: Key.iCloudSyncEnabled) } }
    }

    /// When on, this device is a passive iCloud mirror: it never runs background aggregation
    /// (gated in `BackgroundRefreshManager`). Retention cleanup is also skipped on passive devices
    /// (gated in `AggregationService`). Manual fetches still work. Device-local — never included in
    /// the synced payload (it describes this device's role).
    var isPassiveDevice: Bool {
        get { access(keyPath: \.isPassiveDevice); return defaults.bool(forKey: Key.isPassiveDevice) }
        set { withMutation(keyPath: \.isPassiveDevice) { defaults.set(newValue, forKey: Key.isPassiveDevice) } }
    }

    // MARK: Sync serialization

    /// The allow-listed subset of settings that the iCloud sync layer may push/pull.
    /// Excluded keys (voice, timeline position, onboarding flags, filter state, iCloudSyncEnabled)
    /// are physically absent from this struct and therefore cannot be serialized.
    struct SyncedSettings: Codable {
        var activeAIProvider: String?
        var retentionDays: Int?
        var backgroundInterval: Double?
        var redditEnabled: Bool?
        var redditUserAgent: String?
        var youtubeEnabled: Bool?
        var notificationsEnabled: Bool?
        var openaiAPIURL: String?
        var openaiModel: String?
        var anthropicModel: String?
        var geminiModel: String?
        var mistralModel: String?
        var qwenModel: String?
        var deepseekModel: String?
        var aiTemperature: Double?
        var aiMaxTokens: Int?
        var aiMaxPromptLength: Int?
        var aiDefaultDailyLimit: Int?
        var aiDefaultMonthlyLimit: Int?
        var aiRequestTimeout: Int?
        var aiMaxRetries: Int?
        var aiRetryDelay: Int?
        var aiRequestDelay: Int?
        var articleTextSize: Int?
        var articleFont: Int?
        var useSystemBrowser: Bool?
        var articleFullscreenEnabled: Bool?
        /// The anchored article's identifier (exact within the now-identical timeline). Present only
        /// when this device has iCloud sync on; a receiving device jumps to that exact article.
        var timelineAnchorUID: String?
    }

    /// Snapshot the current synced settings into JSON-encoded `Data`.
    func exportSyncedSettings() -> Data {
        let snapshot = SyncedSettings(
            activeAIProvider: activeAIProvider.rawValue,
            retentionDays: retentionDays,
            backgroundInterval: backgroundInterval,
            redditEnabled: redditEnabled,
            redditUserAgent: redditUserAgent,
            youtubeEnabled: youtubeEnabled,
            notificationsEnabled: notificationsEnabled,
            openaiAPIURL: openaiAPIURL,
            openaiModel: openaiModel,
            anthropicModel: anthropicModel,
            geminiModel: geminiModel,
            mistralModel: mistralModel,
            qwenModel: qwenModel,
            deepseekModel: deepseekModel,
            aiTemperature: aiTemperature,
            aiMaxTokens: aiMaxTokens,
            aiMaxPromptLength: aiMaxPromptLength,
            aiDefaultDailyLimit: aiDefaultDailyLimit,
            aiDefaultMonthlyLimit: aiDefaultMonthlyLimit,
            aiRequestTimeout: aiRequestTimeout,
            aiMaxRetries: aiMaxRetries,
            aiRetryDelay: aiRetryDelay,
            aiRequestDelay: aiRequestDelay,
            articleTextSize: articleTextSize.rawValue,
            articleFont: articleFont.rawValue,
            useSystemBrowser: useSystemBrowser,
            articleFullscreenEnabled: articleFullscreenEnabled,
            timelineAnchorUID: iCloudSyncEnabled ? timelineAnchorSyncUID : nil
        )
        return (try? JSONEncoder().encode(snapshot)) ?? Data()
    }

    /// Apply a synced-settings payload, assigning each present field through the typed setter
    /// so `@Observable` mutations fire and change-notifications post. Missing fields are skipped.
    func applySyncedSettings(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(SyncedSettings.self, from: data) else { return }
        if let raw = decoded.activeAIProvider {
            activeAIProvider = AIProvider(rawValue: raw) ?? activeAIProvider
        }
        if let v = decoded.retentionDays { retentionDays = v }
        if let v = decoded.backgroundInterval { backgroundInterval = v }
        if let v = decoded.redditEnabled { redditEnabled = v }
        if let v = decoded.redditUserAgent { redditUserAgent = v }
        if let v = decoded.youtubeEnabled { youtubeEnabled = v }
        if let v = decoded.notificationsEnabled { notificationsEnabled = v }
        if let v = decoded.openaiAPIURL { openaiAPIURL = v }
        if let v = decoded.openaiModel { openaiModel = v }
        if let v = decoded.anthropicModel { anthropicModel = v }
        if let v = decoded.geminiModel { geminiModel = v }
        if let v = decoded.mistralModel { mistralModel = v }
        if let v = decoded.qwenModel { qwenModel = v }
        if let v = decoded.deepseekModel { deepseekModel = v }
        if let v = decoded.aiTemperature { aiTemperature = v }
        if let v = decoded.aiMaxTokens { aiMaxTokens = v }
        if let v = decoded.aiMaxPromptLength { aiMaxPromptLength = v }
        if let v = decoded.aiDefaultDailyLimit { aiDefaultDailyLimit = v }
        if let v = decoded.aiDefaultMonthlyLimit { aiDefaultMonthlyLimit = v }
        if let v = decoded.aiRequestTimeout { aiRequestTimeout = v }
        if let v = decoded.aiMaxRetries { aiMaxRetries = v }
        if let v = decoded.aiRetryDelay { aiRetryDelay = v }
        if let v = decoded.aiRequestDelay { aiRequestDelay = v }
        if let v = decoded.articleTextSize {
            articleTextSize = ArticleTextSize(rawValue: v) ?? articleTextSize
        }
        if let v = decoded.articleFont {
            articleFont = ArticleFont(rawValue: v) ?? articleFont
        }
        if let v = decoded.useSystemBrowser { useSystemBrowser = v }
        if let v = decoded.articleFullscreenEnabled { articleFullscreenEnabled = v }
        if let uid = decoded.timelineAnchorUID {
            timelineAnchorSyncUID = uid
            NotificationCenter.default.post(name: Self.timelinePositionDidChange, object: self)
        }
    }

    var activeAIProvider: AIProvider {
        get {
            access(keyPath: \.activeAIProvider)
            guard let raw = defaults.string(forKey: Key.activeAIProvider),
                  let provider = AIProvider(rawValue: raw) else { return .none }
            return provider
        }
        set { withMutation(keyPath: \.activeAIProvider) { defaults.set(newValue.rawValue, forKey: Key.activeAIProvider) } }
    }

    var retentionDays: Int {
        get { access(keyPath: \.retentionDays); return defaults.integer(forKey: Key.retentionDays) }
        set { withMutation(keyPath: \.retentionDays) { defaults.set(newValue, forKey: Key.retentionDays) } }
    }

    var backgroundInterval: TimeInterval {
        get { access(keyPath: \.backgroundInterval); return defaults.double(forKey: Key.backgroundInterval) }
        set { withMutation(keyPath: \.backgroundInterval) { defaults.set(newValue, forKey: Key.backgroundInterval) } }
    }

    // MARK: Sources
    var redditEnabled: Bool {
        get { access(keyPath: \.redditEnabled); return defaults.bool(forKey: Key.redditEnabled) }
        set { withMutation(keyPath: \.redditEnabled) { defaults.set(newValue, forKey: Key.redditEnabled) } }
    }
    var redditUserAgent: String {
        get { access(keyPath: \.redditUserAgent); return defaults.string(forKey: Key.redditUserAgent) ?? "Yana/1.0" }
        set { withMutation(keyPath: \.redditUserAgent) { defaults.set(newValue, forKey: Key.redditUserAgent) } }
    }
    var youtubeEnabled: Bool {
        get { access(keyPath: \.youtubeEnabled); return defaults.bool(forKey: Key.youtubeEnabled) }
        set { withMutation(keyPath: \.youtubeEnabled) { defaults.set(newValue, forKey: Key.youtubeEnabled) } }
    }

    /// Whether the given aggregator type's content source is currently active.
    /// Reddit / YouTube are gated by their per-source Enabled toggle; every other
    /// type is always active.
    func isSourceEnabled(_ type: AggregatorType) -> Bool {
        switch type {
        case .reddit: return redditEnabled
        case .youtube: return youtubeEnabled
        default: return true
        }
    }

    var notificationsEnabled: Bool {
        get { access(keyPath: \.notificationsEnabled); return defaults.bool(forKey: Key.notificationsEnabled) }
        set { withMutation(keyPath: \.notificationsEnabled) { defaults.set(newValue, forKey: Key.notificationsEnabled) } }
    }

    // MARK: Providers
    var openaiAPIURL: String {
        get { access(keyPath: \.openaiAPIURL); return defaults.string(forKey: Key.openaiAPIURL) ?? "https://api.openai.com/v1" }
        set { withMutation(keyPath: \.openaiAPIURL) { defaults.set(newValue, forKey: Key.openaiAPIURL) } }
    }
    var openaiModel: String {
        get { access(keyPath: \.openaiModel); return defaults.string(forKey: Key.openaiModel) ?? "gpt-4o-mini" }
        set { withMutation(keyPath: \.openaiModel) { defaults.set(newValue, forKey: Key.openaiModel) } }
    }
    var anthropicModel: String {
        get { access(keyPath: \.anthropicModel); return defaults.string(forKey: Key.anthropicModel) ?? "claude-haiku-4-5-20251001" }
        set { withMutation(keyPath: \.anthropicModel) { defaults.set(newValue, forKey: Key.anthropicModel) } }
    }
    var geminiModel: String {
        get { access(keyPath: \.geminiModel); return defaults.string(forKey: Key.geminiModel) ?? "gemini-2.5-flash" }
        set { withMutation(keyPath: \.geminiModel) { defaults.set(newValue, forKey: Key.geminiModel) } }
    }
    var mistralModel: String {
        get { access(keyPath: \.mistralModel); return defaults.string(forKey: Key.mistralModel) ?? "mistral-small-latest" }
        set { withMutation(keyPath: \.mistralModel) { defaults.set(newValue, forKey: Key.mistralModel) } }
    }
    var qwenModel: String {
        get { access(keyPath: \.qwenModel); return defaults.string(forKey: Key.qwenModel) ?? "qwen3.5-flash" }
        set { withMutation(keyPath: \.qwenModel) { defaults.set(newValue, forKey: Key.qwenModel) } }
    }
    var deepseekModel: String {
        get { access(keyPath: \.deepseekModel); return defaults.string(forKey: Key.deepseekModel) ?? "deepseek-v4-flash" }
        set { withMutation(keyPath: \.deepseekModel) { defaults.set(newValue, forKey: Key.deepseekModel) } }
    }

    // MARK: AI model (generic accessor)
    /// Model currently selected for `provider`. Provides a single generic path over the
    /// per-provider model properties (used by the onboarding AI step); `.none` /
    /// `.appleIntelligence` have no model and return "".
    func aiModel(for provider: AIProvider) -> String {
        switch provider {
        case .openai: openaiModel
        case .anthropic: anthropicModel
        case .gemini: geminiModel
        case .mistral: mistralModel
        case .qwen: qwenModel
        case .deepseek: deepseekModel
        case .none, .appleIntelligence: ""
        }
    }

    func setAIModel(_ value: String, for provider: AIProvider) {
        switch provider {
        case .openai: openaiModel = value
        case .anthropic: anthropicModel = value
        case .gemini: geminiModel = value
        case .mistral: mistralModel = value
        case .qwen: qwenModel = value
        case .deepseek: deepseekModel = value
        case .none, .appleIntelligence: break
        }
    }

    // MARK: AI knobs
    var aiTemperature: Double {
        get { access(keyPath: \.aiTemperature); return defaults.double(forKey: Key.aiTemperature) }
        set { withMutation(keyPath: \.aiTemperature) { defaults.set(newValue, forKey: Key.aiTemperature) } }
    }
    var aiMaxTokens: Int {
        get { access(keyPath: \.aiMaxTokens); return defaults.integer(forKey: Key.aiMaxTokens) }
        set { withMutation(keyPath: \.aiMaxTokens) { defaults.set(newValue, forKey: Key.aiMaxTokens) } }
    }
    var aiMaxPromptLength: Int {
        get { access(keyPath: \.aiMaxPromptLength); return defaults.integer(forKey: Key.aiMaxPromptLength) }
        set { withMutation(keyPath: \.aiMaxPromptLength) { defaults.set(newValue, forKey: Key.aiMaxPromptLength) } }
    }
    var aiDefaultDailyLimit: Int {
        get { access(keyPath: \.aiDefaultDailyLimit); return defaults.integer(forKey: Key.aiDefaultDailyLimit) }
        set { withMutation(keyPath: \.aiDefaultDailyLimit) { defaults.set(newValue, forKey: Key.aiDefaultDailyLimit) } }
    }
    var aiDefaultMonthlyLimit: Int {
        get { access(keyPath: \.aiDefaultMonthlyLimit); return defaults.integer(forKey: Key.aiDefaultMonthlyLimit) }
        set { withMutation(keyPath: \.aiDefaultMonthlyLimit) { defaults.set(newValue, forKey: Key.aiDefaultMonthlyLimit) } }
    }
    var aiRequestTimeout: Int {
        get { access(keyPath: \.aiRequestTimeout); return defaults.integer(forKey: Key.aiRequestTimeout) }
        set { withMutation(keyPath: \.aiRequestTimeout) { defaults.set(newValue, forKey: Key.aiRequestTimeout) } }
    }
    var aiMaxRetries: Int {
        get { access(keyPath: \.aiMaxRetries); return defaults.integer(forKey: Key.aiMaxRetries) }
        set { withMutation(keyPath: \.aiMaxRetries) { defaults.set(newValue, forKey: Key.aiMaxRetries) } }
    }
    var aiRetryDelay: Int {
        get { access(keyPath: \.aiRetryDelay); return defaults.integer(forKey: Key.aiRetryDelay) }
        set { withMutation(keyPath: \.aiRetryDelay) { defaults.set(newValue, forKey: Key.aiRetryDelay) } }
    }
    var aiRequestDelay: Int {
        get { access(keyPath: \.aiRequestDelay); return defaults.integer(forKey: Key.aiRequestDelay) }
        set { withMutation(keyPath: \.aiRequestDelay) { defaults.set(newValue, forKey: Key.aiRequestDelay) } }
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
        !disabledTagNames.isEmpty || !includeUntagged || !disabledFeedNames.isEmpty
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

    // MARK: Timeline position
    var timelineAnchorIdentifier: String? {
        get { access(keyPath: \.timelineAnchorIdentifier); return defaults.string(forKey: Key.timelineAnchorIdentifier) }
        set { withMutation(keyPath: \.timelineAnchorIdentifier) { defaults.set(newValue, forKey: Key.timelineAnchorIdentifier) } }
    }
    /// The canonical UID of the current anchor article, for cross-device sync (exact resolution).
    /// Distinct from `timelineAnchorIdentifier`, which stays a per-feed identifier for local restore.
    var timelineAnchorSyncUID: String? {
        get { access(keyPath: \.timelineAnchorSyncUID); return defaults.string(forKey: Key.timelineAnchorSyncUID) }
        set { withMutation(keyPath: \.timelineAnchorSyncUID) { defaults.set(newValue, forKey: Key.timelineAnchorSyncUID) } }
    }
}
