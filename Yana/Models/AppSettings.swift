import Foundation

enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case none
    case openai
    case anthropic
    case gemini
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Disabled"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
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
        case .appleIntelligence: []
        }
    }

    var defaultModel: String { models.first ?? "" }
}

/// Non-secret user preferences, backed by UserDefaults. Secrets live in `KeychainService`.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

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
    }

    var activeAIProvider: AIProvider {
        get {
            guard let raw = defaults.string(forKey: Key.activeAIProvider),
                  let provider = AIProvider(rawValue: raw) else { return .none }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Key.activeAIProvider) }
    }

    var retentionDays: Int {
        get { defaults.integer(forKey: Key.retentionDays) }
        set { defaults.set(newValue, forKey: Key.retentionDays) }
    }

    var backgroundInterval: TimeInterval {
        get { defaults.double(forKey: Key.backgroundInterval) }
        set { defaults.set(newValue, forKey: Key.backgroundInterval) }
    }

    // MARK: Sources
    var redditEnabled: Bool {
        get { defaults.bool(forKey: Key.redditEnabled) }
        set { defaults.set(newValue, forKey: Key.redditEnabled) }
    }
    var redditUserAgent: String {
        get { defaults.string(forKey: Key.redditUserAgent) ?? "Yana/1.0" }
        set { defaults.set(newValue, forKey: Key.redditUserAgent) }
    }
    var youtubeEnabled: Bool {
        get { defaults.bool(forKey: Key.youtubeEnabled) }
        set { defaults.set(newValue, forKey: Key.youtubeEnabled) }
    }
    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    // MARK: Providers
    var openaiAPIURL: String {
        get { defaults.string(forKey: Key.openaiAPIURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Key.openaiAPIURL) }
    }
    var openaiModel: String {
        get { defaults.string(forKey: Key.openaiModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Key.openaiModel) }
    }
    var anthropicModel: String {
        get { defaults.string(forKey: Key.anthropicModel) ?? "claude-haiku-4-5-20251001" }
        set { defaults.set(newValue, forKey: Key.anthropicModel) }
    }
    var geminiModel: String {
        get { defaults.string(forKey: Key.geminiModel) ?? "gemini-2.5-flash" }
        set { defaults.set(newValue, forKey: Key.geminiModel) }
    }

    // MARK: AI knobs
    var aiTemperature: Double {
        get { defaults.double(forKey: Key.aiTemperature) }
        set { defaults.set(newValue, forKey: Key.aiTemperature) }
    }
    var aiMaxTokens: Int {
        get { defaults.integer(forKey: Key.aiMaxTokens) }
        set { defaults.set(newValue, forKey: Key.aiMaxTokens) }
    }
    var aiMaxPromptLength: Int {
        get { defaults.integer(forKey: Key.aiMaxPromptLength) }
        set { defaults.set(newValue, forKey: Key.aiMaxPromptLength) }
    }
    var aiDefaultDailyLimit: Int {
        get { defaults.integer(forKey: Key.aiDefaultDailyLimit) }
        set { defaults.set(newValue, forKey: Key.aiDefaultDailyLimit) }
    }
    var aiDefaultMonthlyLimit: Int {
        get { defaults.integer(forKey: Key.aiDefaultMonthlyLimit) }
        set { defaults.set(newValue, forKey: Key.aiDefaultMonthlyLimit) }
    }
    var aiRequestTimeout: Int {
        get { defaults.integer(forKey: Key.aiRequestTimeout) }
        set { defaults.set(newValue, forKey: Key.aiRequestTimeout) }
    }
    var aiMaxRetries: Int {
        get { defaults.integer(forKey: Key.aiMaxRetries) }
        set { defaults.set(newValue, forKey: Key.aiMaxRetries) }
    }
    var aiRetryDelay: Int {
        get { defaults.integer(forKey: Key.aiRetryDelay) }
        set { defaults.set(newValue, forKey: Key.aiRetryDelay) }
    }
    var aiRequestDelay: Int {
        get { defaults.integer(forKey: Key.aiRequestDelay) }
        set { defaults.set(newValue, forKey: Key.aiRequestDelay) }
    }

    // MARK: Timeline filter
    /// Names of tags currently toggled OFF in the filter. Empty = all active.
    var disabledTagNames: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.disabledTagNames) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.disabledTagNames) }
    }
    var includeUntagged: Bool {
        get { defaults.bool(forKey: Key.includeUntagged) }
        set { defaults.set(newValue, forKey: Key.includeUntagged) }
    }

    // MARK: Timeline position
    var timelineAnchorIdentifier: String? {
        get { defaults.string(forKey: Key.timelineAnchorIdentifier) }
        set { defaults.set(newValue, forKey: Key.timelineAnchorIdentifier) }
    }
}
