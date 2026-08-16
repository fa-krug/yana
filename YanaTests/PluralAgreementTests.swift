import Foundation
import Testing
@testable import Yana

/// Count-bearing user-facing strings must agree in number.
///
/// The String Catalog falls back to the flat key when a language has no plural variation, so keys
/// like `"%lld articles"` — which had variations for `de` only — rendered "1 articles" in English,
/// the source language and therefore the default for most users.
///
/// Each string is resolved through the compiled catalog exactly as the UI resolves it, against an
/// explicit `.lproj` bundle. Following `RefreshOutcomeTests`' note: the simulator's language is not
/// guaranteed to be English, so the language has to be pinned rather than assumed — and `locale:`
/// alone does not do it (it selects plural *rules*, not the localization).
struct PluralAgreementTests {

    private static func bundle(_ language: String) -> Bundle? {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    private func render(_ value: String.LocalizationValue, _ language: String) throws -> String {
        let bundle = try #require(Self.bundle(language),
                                  "no \(language).lproj in the app bundle")
        return String(localized: value, bundle: bundle, locale: Locale(identifier: language))
    }

    private func en(_ value: String.LocalizationValue) throws -> String { try render(value, "en") }
    private func de(_ value: String.LocalizationValue) throws -> String { try render(value, "de") }

    /// Control: `"%lld entries"` already had both localizations, so this passes before *and* after
    /// the fix. If per-language bundle resolution ever silently falls back, this fails first and
    /// says so, instead of the real assertions failing for the wrong reason.
    @Test func perLanguageResolutionWorks() throws {
        #expect(try en("\(1) entries") == "1 entry")
        #expect(try en("\(9) entries") == "9 entries")
        #expect(try de("\(1) entries") == "1 Eintrag")
        #expect(try de("\(9) entries") == "9 Einträge")
    }

    @Test func feedRowArticleCountAgrees() throws {
        #expect(try en("\(1) articles") == "1 article")
        #expect(try en("\(2) articles") == "2 articles")
        #expect(try en("\(0) articles") == "0 articles")
        // German was already correct — "Artikel" is both forms; pinned so it stays that way.
        #expect(try de("\(1) articles") == "1 Artikel")
        #expect(try de("\(2) articles") == "2 Artikel")
    }

    @Test func feedValidationArticleCountAgrees() throws {
        #expect(try en("Feed valid — \(1) articles") == "Feed valid — 1 article")
        #expect(try en("Feed valid — \(7) articles") == "Feed valid — 7 articles")
    }

    /// The retention stepper's range starts at 1, so the singular is reachable — and unlike
    /// "Artikel", German "Tag"/"Tage" really does change.
    @Test func retentionDayCountAgrees() throws {
        #expect(try en("Keep Articles: \(1) days") == "Keep Articles: 1 day")
        #expect(try en("Keep Articles: \(30) days") == "Keep Articles: 30 days")
        #expect(try de("Keep Articles: \(1) days") == "Artikel behalten: 1 Tag")
        #expect(try de("Keep Articles: \(30) days") == "Artikel behalten: 30 Tage")
    }

    /// Here the count is the *second* argument, so agreement needs a substitution rather than a
    /// whole-string plural variation (which keys on the first argument).
    @Test func deleteFeedConfirmationArticleCountAgrees() throws {
        #expect(try en("Delete “\("Acme")”? Its \(1) articles will be permanently deleted.")
                == "Delete “Acme”? Its 1 article will be permanently deleted.")
        #expect(try en("Delete “\("Acme")”? Its \(4) articles will be permanently deleted.")
                == "Delete “Acme”? Its 4 articles will be permanently deleted.")
    }

    @Test func opmlImportSummaryFeedCountAgrees() throws {
        #expect(try en("Imported \(1) feeds, skipped \(0).") == "Imported 1 feed, skipped 0.")
        #expect(try en("Imported \(3) feeds, skipped \(2).") == "Imported 3 feeds, skipped 2.")
        #expect(try de("Imported \(1) feeds, skipped \(0).") == "1 Feed importiert, 0 übersprungen.")
        #expect(try de("Imported \(3) feeds, skipped \(2).") == "3 Feeds importiert, 2 übersprungen.")
    }

    /// The diagnostics header's library row — four independent counts in one string.
    @Test func diagnosticsLibraryRowCountsAgree() throws {
        #expect(try en("\(1) feeds · \(1) tags · \(1) articles · \(1) images")
                == "1 feed · 1 tag · 1 article · 1 image")
        #expect(try en("\(2) feeds · \(3) tags · \(4) articles · \(5) images")
                == "2 feeds · 3 tags · 4 articles · 5 images")
        #expect(try de("\(1) feeds · \(1) tags · \(1) articles · \(1) images")
                == "1 Feed · 1 Tag · 1 Artikel · 1 Bild")
        #expect(try de("\(2) feeds · \(3) tags · \(4) articles · \(5) images")
                == "2 Feeds · 3 Tags · 4 Artikel · 5 Bilder")
    }



    /// `RefreshOutcome.message` used to splice a separately-localized bare noun ("article"/
    /// "articles") into a template string, which can't agree grammatically in German ("1 neue
    /// Artikel" instead of "1 neuer Artikel"). It now uses two whole-string plural-keyed templates
    /// directly, with the count as the sole (or first) substitution argument.
    @Test func addedNewArticlesAgreesInBothLanguages() throws {
        #expect(try en("Added \(1) new articles.") == "Added 1 new article.")
        #expect(try en("Added \(2) new articles.") == "Added 2 new articles.")
        #expect(try de("Added \(1) new articles.") == "1 neuer Artikel hinzugefügt.")
        #expect(try de("Added \(2) new articles.") == "2 neue Artikel hinzugefügt.")
    }

    @Test func addedNewArticlesFromFeedAgreesInBothLanguages() throws {
        #expect(try en("Added \(1) new articles from “\("Heise")”.")
                == "Added 1 new article from “Heise”.")
        #expect(try en("Added \(2) new articles from “\("Heise")”.")
                == "Added 2 new articles from “Heise”.")
        #expect(try de("Added \(1) new articles from “\("Heise")”.")
                == "1 neuer Artikel von „Heise“ hinzugefügt.")
        #expect(try de("Added \(2) new articles from “\("Heise")”.")
                == "2 neue Artikel von „Heise“ hinzugefügt.")
    }

    /// The notification title already handled English through `inflect: true` automatic grammar
    /// agreement, with an explicit `de` block. Pinned so a catalog edit can't quietly break it.
    @Test func newArticleNotificationTitleAgrees() throws {
        #expect(try en("^[\(1) new article](inflect: true)") == "1 new article")
        #expect(try en("^[\(4) new article](inflect: true)") == "4 new articles")
        #expect(try de("^[\(1) new article](inflect: true)") == "1 neuer Artikel")
        #expect(try de("^[\(4) new article](inflect: true)") == "4 neue Artikel")
    }
}
