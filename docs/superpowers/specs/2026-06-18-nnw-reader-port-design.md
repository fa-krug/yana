# NetNewsWire Reader Port — Design

Date: 2026-06-18
Status: Approved (pending spec review)

## Goal

Replace Yana's current SwiftUI reader surface with a faithful port of NetNewsWire's
(NNW) UIKit reader so the home view behaves exactly like NNW. This fixes two standing
layout bugs and adds three NNW features the user explicitly wants:

- **Bug:** on load the article title renders *behind* the floating top toolbar.
- **Bug:** the floating bottom action bar sits too high above the home indicator.
- **Feature:** full-screen reading (tap to hide/show bars).
- **Feature:** open links in the native browser.
- **Feature:** the NNW article **theme system**.

Reference source: `/private/tmp/nnw-ref` (NetNewsWire 7, iOS target under `iOS/`,
shared rendering under `Shared/Article Rendering/` and `Shared/ArticleStyles/`).

## Root cause of the bugs (why a port fixes them)

Both apps pin a full-screen `WKWebView` under the bars and render the title inside the
HTML. The difference is inset handling and chrome:

- **NNW** uses real UIKit bars (`UINavigationBar` + `UIToolbar`) with an **opaque**
  background (`UINavigationBarAppearance().configureWithDefaultBackground()`,
  `ArticleViewController.swift:120`). Because the bars are opaque and managed by a
  `UINavigationController`, the view controller's safe area *includes the bar heights*,
  so WKWebView's **automatic** content-inset adjustment makes content start below the
  nav bar and end above the toolbar. NNW never hand-computes an inset.
- **Yana** makes the bars transparent (`.toolbarBackground(.hidden)`), turns *off*
  automatic adjustment (`contentInsetAdjustmentBehavior = .never`), and applies a
  **manual** inset captured *outside* the `NavigationStack` (device inset = status bar
  only, ~59pt — missing the ~44pt nav bar), so the title lands behind the bar. The
  bottom uses a hand-built floating glass capsule whose overlay double-counts the
  home-indicator inset, lifting it too high.

Adopting NNW's opaque-bars + automatic-insets architecture removes all the hand-tuned
inset/floating-glass code and eliminates both bugs by construction.

## Scope decisions (locked)

- **Hosting:** full UIKit port hosted in SwiftUI via `UIViewControllerRepresentable`.
- **Theme system:** local themes + picker only. Port the manager + renderer + bundle
  NNW's 8 `.nnwtheme` themes. **No** theme import-from-Files, **no** online gallery
  download.
- **Optional reader extras:** none — **no** image tap-to-zoom, **no** find-in-article,
  **no** footnote popovers. (Consequently the JS files `main.js` / `newsfoot.js` are
  *not* ported, and the outer page template drops their `<script>` tags.)
- **Article extractor (NNW "Reader View"):** dropped — Yana already aggregates full
  content on-device and has no Mercury-style parser. No extractor button.

## 1. Architecture & hosting

- **`ReaderHostView`** — a new `UIViewControllerRepresentable` wrapping a
  `UINavigationController` whose root is the ported `ArticleViewController`. Lives in
  `ContentView`, alongside the existing `.sheet`s for Settings/Filter driven by
  `AppState`.
- **SwiftUI ⇄ UIKit bridge:** the representable passes the filtered `[Article]` and the
  selected index down, and reports index changes back into `appState.currentIndex`
  (preserving the existing anchor / position-memory logic from `ArticleReaderView`).
  It forwards `onRefresh`. Nav/toolbar buttons flip `appState.showSettings` /
  `appState.showFilter`, so the **existing SwiftUI sheets are reused unchanged**.
- The `UINavigationController` uses an **opaque** nav bar + toolbar
  (`configureWithDefaultBackground()` on standard/scrollEdge/compact), so the web view
  can use WKWebView's **automatic** content-inset adjustment — the fix.

## 2. Reader chrome & full-screen

Port `ArticleViewController` + `WebViewController`, adapted to Yana's models and trimmed
of NNW dependencies (`Account`, `SceneCoordinator`, `ArticleExtractor`, search,
keyboard manager).

- **Paging:** `UIPageViewController(transitionStyle: .scroll, navigationOrientation:
  .horizontal)` over the timeline, using NNW's data-source/delegate pattern. Replaces
  `ArticlePagerView`. Keeps Yana's pull-to-refresh `UIRefreshControl` on the web scroll
  view (fire-and-forget retract, progress shown by the nav indicator).
- **Bars:**
  - Top-left group: **Filter** button, then the **refresh/loading indicator**
    (`UIActivityIndicatorView`/`ProgressView` equivalent) at the *rightmost* of the
    left group, shown only while a refresh is running.
  - Top-right: **Settings** button.
  - Bottom `UIToolbar`: **Star** (toggles the built-in Starred tag on the current
    article), **Share**, **Open in Browser**. No read/unread, no next-unread (Yana has
    no read state).
- **Full-screen:** port `hideBars()` / `showBars()` plus the top/bottom 44pt
  transparent tap-zone views and tap-the-nav-bar-to-hide (`didTapNavigationBar`). Hides
  nav bar, toolbar, and status bar; the iOS 26 bottom scroll-edge effect is toggled
  with the bars. Persisted via a new runtime flag `AppSettings.articleFullscreenEnabled`
  so the hidden state carries across articles and launches (NNW behavior). Available on
  iPhone only (NNW gates full-screen to the phone idiom).

## 3. Rendering & theme port

Port NNW's renderer + theme stack, adapted to Yana's `Article`/`Feed`.

### Files ported (adapted)
- `ArticleRenderer` (`Shared/Article Rendering/ArticleRenderer.swift`) — produces
  `(style, html, title, baseURL)` from an article + theme.
- `MacroProcessor` (`Modules/RSCore/.../MacroProcessor.swift`) — `[[macro]]`
  substitution into templates.
- `ArticleTextSize` (`Shared/Article Rendering/ArticleTextSize.swift`) — text-size
  cases + CSS class + font multiplier.
- Outer page template (Yana's own, based on `iOS/Resources/page.html`) — **drops** the
  `main.js` / `main_ios.js` / `newsfoot.js` `<script>` tags and the `processPage()` /
  `window.scrollTo` bootstrap. Within-article scroll restore is *not* ported (Yana
  restores which-article via its timeline anchor, not scroll-Y).
- `core.css` (`Shared/Article Rendering/core.css`) — shared rules (ad-block selectors,
  zoom indicator markup is unused but harmless).

### Theme stack ported
- `ArticleTheme`, `ArticleThemePlist`, `ArticleThemesManager`
  (`Shared/ArticleStyles/`), adapted: enumerate **bundled** themes only, track the
  current theme name in `AppSettings`, and post a change notification that the
  `WebViewController` observes to re-render. Drop `ArticleThemeDownloader`,
  `ArticleTheme+Notifications` remote bits, `ArticleThemeImporter`, and
  `ArticleThemesTableViewController` (NNW's UIKit settings screen — replaced by a
  SwiftUI picker, §5).
- Bundle NNW's **8** `.nnwtheme` folders (each = `template.html` + `stylesheet.css` +
  `Info.plist`) as app resources via `project.yml`:
  Appanoose, Biblioteca, Hyperlegible, NewsFax, Promenade, Sepia, Tiqoe Dark,
  Verdana Revival. Default theme: the same default NNW ships (Promenade-equivalent /
  the NNW default theme name).

### Macro mapping (NNW → Yana)
The theme `template.html` expects these macros; filled from Yana's `Article`/`Feed`:

| Macro | Yana source |
|---|---|
| `title` | `article.title` |
| `preferred_link`, `external_link` | `article.url` |
| `external_link_label` / `external_link_stripped` | "Link:" + URL minus scheme (empty if no URL) |
| `byline` | `article.author` (empty → omitted) |
| `feed_link_title` | `article.feed?.name` |
| `feed_link` | feed home page; derived from `article.url` host when absent |
| `datetime_medium` (+ other date/time forms) | `article.date` via the corresponding formatters |
| `dateline_style` | `articleDatelineTitle` when title empty, else `articleDateline` |
| `body` | `article.content` |
| `avatar_src` | existing `ArticleHeaderLogo` / `ImageSchemeHandler` → `yana-img://<logoHash>` (empty when no logo) |
| `text_size_class` | `AppSettings` text-size → `ArticleTextSize.cssClass` |
| style `font-size` | `UIFont.preferredFont(forTextStyle:.body).pointSize` × text-size multiplier |

Reuses Yana's `ImageSchemeHandler`, `ContentFormatter`, `ArticleHeaderLogo`,
`ReaderWeb` (base origin / image scheme constants).

## 4. Native browser & links

- Ported `WebViewController.decidePolicyFor` / `openURL`: tapped links and
  `target="_blank"` open in the **native browser** — `SFSafariViewController` by
  default, or the system browser (`UIApplication.shared.open`) when the new
  `AppSettings.useSystemBrowser` toggle is on. `mailto:` / `tel:` handled as in NNW.
- **Removes** `LinkWebView` / `LinkSheet` (the in-app web sheet).

## 5. Settings additions (`SettingsScreenView`)

New **Reader** section:
- **Theme** picker — installed themes from `ArticleThemesManager` (display names from
  each theme's `Info.plist`).
- **Article text size** — stepper/segmented over `ArticleTextSize` cases.
- **Use system browser** — toggle (`AppSettings.useSystemBrowser`, default off →
  `SFSafariViewController`).

(`articleFullscreenEnabled` is runtime state set by tapping, not a visible toggle.)

### New `AppSettings` keys
- `readerThemeName: String` (default = NNW default theme name).
- `articleTextSize: String` (raw value of `ArticleTextSize`, default medium).
- `useSystemBrowser: Bool` (default false).
- `articleFullscreenEnabled: Bool` (default false; runtime fullscreen state).

## 6. Files removed / changed

- **Remove:** `ArticleReaderView.swift`, `ArticlePagerView.swift`,
  `ArticleContentView.swift`, `ArticleWebView.swift`, `LinkWebView.swift`.
- **Replace:** `ContentView` → hosts `ReaderHostView`. `ArticleDetailView` (config-hub
  search detail) re-uses the ported web rendering in a **non-paging, non-full-screen,
  standard-inset** mode (a lightweight wrapper around the ported `WebViewController` or
  a shared render-only web view) instead of `ArticleContentView`.
- **Keep/reuse:** `ImageSchemeHandler`, `ContentFormatter`, `ArticleHeaderLogo`,
  `ReaderWeb`, the anchor / position-memory logic (moved into `ReaderHostView`/the
  representable), pull-to-refresh, `ShareSheet`.
- **`project.yml`:** add the 8 `.nnwtheme` bundles + ported CSS/template resources;
  run `xcodegen generate` afterward.

## 7. Localization & testing

- All new user-facing strings (Reader section title, theme picker label, text-size
  label, "Use system browser", "Open in Browser", "Link:") added to
  `Localizable.xcstrings` with German translations marked `translated`, per project
  rules. Theme **display names** come from each theme's `Info.plist` (not localized).
- **Tests** (Swift Testing, `@MainActor`):
  - `MacroProcessor` — substitutes `[[macro]]` tokens, leaves unknown tokens / handles
    escaping as NNW does.
  - `ArticleRenderer` — for a sample `Article` + a bundled theme, the rendered HTML
    contains the title, body, byline, dateline, and avatar `src`; empty author/logo are
    omitted cleanly.
  - `ArticleThemesManager` — enumerates the 8 bundled themes, exposes the default, and
    switching the current theme persists + reports the new theme.
  - UIKit chrome / full-screen / native-browser behavior verified manually
    (`xcodebuild ... build`, then in the simulator).

## Risks / notes

- This **removes the Liquid-Glass floating reader chrome** in favor of NNW's opaque
  native bars — intended, and the core of the fix.
- NNW's `ArticleRenderer` carries macOS/iOS branches and Account-model assumptions;
  the port keeps only the iOS path and rewires model access to Yana's `Article`/`Feed`.
- `project.yml` resource globbing must include the `.nnwtheme` folder contents; verify
  the bundles are copied (not flattened) so `template.html`/`stylesheet.css`/`Info.plist`
  resolve at runtime.
