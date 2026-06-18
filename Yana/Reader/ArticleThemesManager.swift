import Foundation

/// Registry of bundled article themes plus the user's current selection. Adapted from
/// NetNewsWire to load only app-bundled themes (no Themes folder, no import/download).
@MainActor
final class ArticleThemesManager {
    static let shared = ArticleThemesManager()

    static let currentThemeDidChange = Notification.Name("YanaCurrentArticleThemeDidChange")

    private static let themeNameKey = "settings.readerThemeName"

    private(set) var themeNames: [String]
    private(set) var currentTheme: ArticleTheme

    /// The name of the resolved `currentTheme`. The change guard compares against this rather than
    /// the persisted key, because callers (the Settings picker) may write the shared
    /// `settings.readerThemeName` key *before* calling us — comparing against the key would then
    /// see no change and silently skip the re-resolve + notification, requiring an app restart.
    private var currentName: String

    var currentThemeName: String {
        get {
            UserDefaults.standard.string(forKey: Self.themeNameKey) ?? ArticleTheme.defaultThemeName
        }
        set {
            guard newValue != currentName else { return }
            UserDefaults.standard.set(newValue, forKey: Self.themeNameKey)
            updateCurrentTheme()
            NotificationCenter.default.post(name: Self.currentThemeDidChange, object: self)
        }
    }

    private init() {
        self.themeNames = Self.allThemeNames()
        self.currentTheme = ArticleTheme.defaultTheme
        self.currentName = ArticleTheme.defaultThemeName
        updateCurrentTheme()
    }

    /// Resolve a theme by name; nil if not bundled. "Default" → built-in theme.
    func theme(named themeName: String) -> ArticleTheme? {
        if themeName == ArticleTheme.defaultThemeName {
            return ArticleTheme.defaultTheme
        }
        // Themes are stored under the Themes/ subdirectory in the app bundle
        guard let url = Bundle.main.url(forResource: themeName,
                                        withExtension: ArticleTheme.nnwThemeSuffix,
                                        subdirectory: "Themes") else {
            return nil
        }
        return try? ArticleTheme(url: url)
    }

    private func updateCurrentTheme() {
        var name = currentThemeName
        if !themeNames.contains(name) {
            name = ArticleTheme.defaultThemeName
            UserDefaults.standard.set(name, forKey: Self.themeNameKey)
        }
        currentName = name
        currentTheme = theme(named: name) ?? ArticleTheme.defaultTheme
    }

    private static func allThemeNames() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: ArticleTheme.nnwThemeSuffix,
                                    subdirectory: "Themes") ?? []
        let bundled = urls.map { ArticleTheme.themeNameForPath($0.path) }
            .sorted { $0.compare($1, options: .caseInsensitive) == .orderedAscending }
        return [ArticleTheme.defaultThemeName] + bundled
    }
}
