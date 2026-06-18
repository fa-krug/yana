import Testing
import Foundation
@testable import Yana

@MainActor
struct ArticleThemesManagerTests {
    @Test func enumeratesDefaultPlusBundledThemes() {
        let names = ArticleThemesManager.shared.themeNames
        #expect(names.first == ArticleTheme.defaultThemeName)
        #expect(names.contains("Sepia"))
        #expect(names.contains("Promenade"))
        #expect(names.count >= 9) // Default + 8 bundled
    }

    @Test func switchingThemePersistsAndResolves() {
        let manager = ArticleThemesManager.shared
        manager.currentThemeName = "Sepia"
        #expect(manager.currentThemeName == "Sepia")
        #expect(manager.currentTheme.name == "Sepia")
        #expect(manager.currentTheme.css?.isEmpty == false)
        manager.currentThemeName = ArticleTheme.defaultThemeName // reset for other tests
    }

    @Test func unknownThemeFallsBackToDefault() {
        let manager = ArticleThemesManager.shared
        manager.currentThemeName = "NoSuchTheme-xyz"
        #expect(manager.currentThemeName == ArticleTheme.defaultThemeName)
        manager.currentThemeName = ArticleTheme.defaultThemeName
    }

    /// Reproduces the reader's live-theme bug: the Settings picker writes the shared
    /// `settings.readerThemeName` UserDefaults key *before* calling the manager. The manager must
    /// still detect the change (resolve the new theme and post `currentThemeDidChange`) so the
    /// reader re-renders without an app restart.
    @Test func switchingThemeUpdatesWhenSharedKeyPrewritten() {
        let manager = ArticleThemesManager.shared
        manager.currentThemeName = ArticleTheme.defaultThemeName // baseline

        // Simulate AppSettings.readerThemeName writing the same key first.
        UserDefaults.standard.set("Sepia", forKey: "settings.readerThemeName")

        nonisolated(unsafe) var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: ArticleThemesManager.currentThemeDidChange, object: nil, queue: nil
        ) { _ in posted = true }

        manager.currentThemeName = "Sepia"
        NotificationCenter.default.removeObserver(token)

        #expect(posted)
        #expect(manager.currentTheme.name == "Sepia")
        manager.currentThemeName = ArticleTheme.defaultThemeName // reset for other tests
    }
}
