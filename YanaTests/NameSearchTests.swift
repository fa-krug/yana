import Foundation
import Testing
@testable import Yana

@Suite("NameSearch")
struct NameSearchTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(NameSearch.matches("Heise", query: "   "))
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(NameSearch.matches("Méin MMO", query: "mein"))
        #expect(NameSearch.matches("Tagesschau", query: "TAGES"))
    }

    @Test func nonMatchExcluded() {
        #expect(!NameSearch.matches("Heise", query: "reddit"))
    }

    @Test func filterReturnsOnlyMatches() {
        let names = ["Heise", "Reddit", "heise blog"]
        #expect(NameSearch.filter(names, query: "heise", name: { $0 }).count == 2)
    }
}
