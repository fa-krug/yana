import Foundation

enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case none
    case openai
    case anthropic
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Disabled"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        }
    }
}

/// Non-secret user preferences, backed by UserDefaults. Secrets live in `KeychainService`.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let activeAIProvider = "settings.activeAIProvider"
        static let retentionDays = "settings.retentionDays"
        static let backgroundInterval = "settings.backgroundInterval"
    }

    var activeAIProvider: AIProvider {
        get {
            guard let raw = defaults.string(forKey: Key.activeAIProvider),
                  let provider = AIProvider(rawValue: raw) else { return .none }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Key.activeAIProvider) }
    }

    /// Read articles older than this many days are eligible for cleanup. Default 30.
    var retentionDays: Int {
        get {
            let value = defaults.integer(forKey: Key.retentionDays)
            return value == 0 ? 30 : value
        }
        set { defaults.set(newValue, forKey: Key.retentionDays) }
    }

    /// Background refresh interval in seconds. Default 1800 (30 min).
    var backgroundInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.backgroundInterval)
            return value == 0 ? 1800 : value
        }
        set { defaults.set(newValue, forKey: Key.backgroundInterval) }
    }
}
