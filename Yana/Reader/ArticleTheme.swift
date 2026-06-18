import Foundation

/// One article theme: the body `template.html` and combined `core.css` + theme `stylesheet.css`.
/// The default theme uses the app's bundled `stylesheet.css`/`template.html`; named themes load
/// from a bundled `.nnwtheme` folder. Adapted from NetNewsWire (local bundles only).
struct ArticleTheme: Equatable, Sendable {

    static let nnwThemeSuffix = ".nnwtheme"
    static let defaultThemeName = String(localized: "Default")

    let url: URL?
    let template: String?
    let css: String?
    let name: String

    /// The built-in default theme: app `core.css` + `stylesheet.css` + `template.html`.
    static let defaultTheme = ArticleTheme()

    private init() {
        self.url = nil
        self.name = Self.defaultThemeName
        let core = Self.bundledString("core", "css")
        let sheet = Self.bundledString("stylesheet", "css")
        self.css = (core ?? "") + "\n" + (sheet ?? "")
        self.template = Self.bundledString("template", "html")
    }

    /// A named theme loaded from a `.nnwtheme` folder URL. core.css is prepended so themes share
    /// the base rules; the theme supplies its own stylesheet.css + template.html.
    init(url: URL) throws {
        self.url = url
        self.name = Self.themeNameForPath(url.path)

        let core = Bundle.main.url(forResource: "core", withExtension: "css")
            .flatMap { Self.stringAtPath($0.path) } ?? ""
        if let sheet = Self.stringAtPath(url.appendingPathComponent("stylesheet.css").path) {
            self.css = core + "\n" + sheet
        } else {
            self.css = nil
        }
        self.template = Self.stringAtPath(url.appendingPathComponent("template.html").path)

        let data = try Data(contentsOf: url.appendingPathComponent("Info.plist"))
        // Decode to validate the bundle is a well-formed theme; the display name comes from the folder name.
        _ = try PropertyListDecoder().decode(ArticleThemePlist.self, from: data)
    }

    private static func bundledString(_ name: String, _ ext: String) -> String? {
        guard let path = Bundle.main.path(forResource: name, ofType: ext) else { return nil }
        return stringAtPath(path)
    }

    static func stringAtPath(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var encoding = String.Encoding.utf8
        return try? String(contentsOfFile: path, usedEncoding: &encoding)
    }

    static func themeNameForPath(_ path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        if filename.hasSuffix(nnwThemeSuffix) {
            return String(filename.dropLast(nnwThemeSuffix.count))
        }
        return filename
    }

    static func pathIsPathForThemeName(_ themeName: String, path: String) -> Bool {
        themeNameForPath(path) == themeName
    }
}
