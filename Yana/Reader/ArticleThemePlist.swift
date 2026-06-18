import Foundation

/// Decodes a `.nnwtheme` bundle's Info.plist. Ported from NetNewsWire.
struct ArticleThemePlist: Codable, Equatable, Sendable {
    let name: String
    let themeIdentifier: String
    let creatorHomePage: String
    let creatorName: String
    let version: Int

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case themeIdentifier = "ThemeIdentifier"
        case creatorHomePage = "CreatorHomePage"
        case creatorName = "CreatorName"
        case version = "Version"
    }
}
