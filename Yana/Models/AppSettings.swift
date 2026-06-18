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
}

/// Non-secret user preferences, backed by UserDefaults. Secrets live in `KeychainService`.
@MainActor
@Observable
final class AppSettings {
    /// Posted when `articleTextSize` changes so the reader can re-render live (no app restart).
    static let articleTextSizeDidChange = Notification.Name("YanaArticleTextSizeDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.retentionDays: 30,
            Key.backgroundInterval: 1800.0,
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
        // Timeline position
        static let timelineAnchorIdentifier = "settings.timelineAnchorIdentifier"
        // Reader
        static let readerThemeName = "settings.readerThemeName"
        static let articleTextSize = "settings.articleTextSize"
        static let useSystemBrowser = "settings.useSystemBrowser"
        static let articleFullscreenEnabled = "settings.articleFullscreenEnabled"
        static let hasSeenFullscreenHint = "settings.hasSeenFullscreenHint"
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
    /// True when the timeline filter would hide some articles (a tag is off, or untagged
    /// articles are excluded). Drives the reader's filter-button active state.
    var isTimelineFilterActive: Bool {
        !disabledTagNames.isEmpty || !includeUntagged
    }

    // MARK: Reader
    var readerThemeName: String {
        get { access(keyPath: \.readerThemeName); return defaults.string(forKey: Key.readerThemeName) ?? ArticleTheme.defaultThemeName }
        set { withMutation(keyPath: \.readerThemeName) { defaults.set(newValue, forKey: Key.readerThemeName) } }
    }
    var articleTextSize: ArticleTextSize {
        get { access(keyPath: \.articleTextSize); return ArticleTextSize(rawValue: defaults.integer(forKey: Key.articleTextSize)) ?? .medium }
        set {
            let changed = newValue != articleTextSize
            withMutation(keyPath: \.articleTextSize) { defaults.set(newValue.rawValue, forKey: Key.articleTextSize) }
            if changed { NotificationCenter.default.post(name: Self.articleTextSizeDidChange, object: self) }
        }
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

    // MARK: Timeline position
    var timelineAnchorIdentifier: String? {
        get { access(keyPath: \.timelineAnchorIdentifier); return defaults.string(forKey: Key.timelineAnchorIdentifier) }
        set { withMutation(keyPath: \.timelineAnchorIdentifier) { defaults.set(newValue, forKey: Key.timelineAnchorIdentifier) } }
    }
}
