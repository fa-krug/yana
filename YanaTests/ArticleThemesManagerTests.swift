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
}
