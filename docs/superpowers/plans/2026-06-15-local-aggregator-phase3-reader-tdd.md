# Local Aggregator Phase 3 (Endless-Timeline Reader) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the interim swipe view with the real home surface — a single endless, date-ordered timeline of all articles with tag filtering, starring, remembered position, and pull-to-refresh.

**Architecture:** Pure SwiftUI + SwiftData. A `@Query` of all articles (sorted by `date` desc) is filtered in-memory by the persisted tag filter (`TagFilter`), the position anchor is resolved via `TimelineAnchor`, starring toggles the built-in Starred tag, and pull-to-refresh drives the Phase 2 `AggregationService` stub (current article + whole timeline).

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), SwiftUI, SwiftData, Swift Testing (`import Testing`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-06-15-local-aggregator-design.md`
**Depends on:** Phase 2 (`docs/superpowers/plans/2026-06-15-local-aggregator-phase2-config-tdd.md`) complete and merged — provides `Tag`, `Article.isStarred`/`setStarred`, `AggregationService`, `ConfigHubView`, and the expanded `AppSettings` (`disabledTagNames`, `includeUntagged`, `timelineAnchorIdentifier`).

**Definition of done (Phase 3):** the reader shows the global timeline, swipes both directions, persists/restores position, stars the current article, filters by tags (incl. Untagged), and pull-to-refresh runs the stub without error. All tests pass.

**Conventions for every task:**
- Tests live in `YanaTests/`; after adding files run `xcodegen generate`.
- Test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
- Build-only: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`

---

## Task 1: Pure logic helpers — tag filter + timeline anchor

**Files:**
- Create: `Yana/Utilities/TimelineFiltering.swift`
- Test: `YanaTests/TimelineFilteringTests.swift`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/TimelineFilteringTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Timeline filtering + anchor")
struct TimelineFilteringTests {
    private func article(_ id: String, tags: [Tag]) -> Article {
        let a = Article(title: id, identifier: id, url: "https://x.com/\(id)")
        a.tags = tags
        return a
    }

    @Test func untaggedRespectsToggle() {
        let a = article("a", tags: [])
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: true).count == 1)
        #expect(TagFilter.apply(to: [a], disabledTagNames: [], includeUntagged: false).isEmpty)
    }

    @Test func showsArticleWithAnyActiveTag() {
        let tech = Tag(name: "Tech")
        let fun = Tag(name: "Fun")
        let a = article("a", tags: [tech, fun])
        // Tech disabled but Fun active -> still shown.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech"], includeUntagged: true).count == 1)
        // Both disabled -> hidden.
        #expect(TagFilter.apply(to: [a], disabledTagNames: ["Tech", "Fun"], includeUntagged: true).isEmpty)
    }

    @Test func anchorResolvesToIndexOrZero() {
        let a = article("a", tags: [])
        let b = article("b", tags: [])
        let list = [a, b]
        #expect(TimelineAnchor.index(for: "b", in: list) == 1)
        #expect(TimelineAnchor.index(for: "missing", in: list) == 0)
        #expect(TimelineAnchor.index(for: nil, in: list) == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: FAIL — `TagFilter` / `TimelineAnchor` undefined.

- [ ] **Step 3: Create the helpers**

Create `Yana/Utilities/TimelineFiltering.swift`:

```swift
import Foundation

/// Filters the timeline by active tags. OR semantics: an article is shown if it has at
/// least one tag that is *not* disabled. Untagged articles are shown only when
/// `includeUntagged` is true.
enum TagFilter {
    static func apply(to articles: [Article], disabledTagNames: Set<String>, includeUntagged: Bool) -> [Article] {
        articles.filter { article in
            let names = Set(article.tags.map(\.name))
            if names.isEmpty { return includeUntagged }
            return !names.isSubset(of: disabledTagNames)
        }
    }
}

/// Resolves the persisted timeline anchor (an article `identifier`) to an index in the
/// currently displayed list, falling back to 0 (newest) when it is missing.
enum TimelineAnchor {
    static func index(for identifier: String?, in articles: [Article]) -> Int {
        guard let identifier,
              let idx = articles.firstIndex(where: { $0.identifier == identifier }) else { return 0 }
        return idx
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: tag filter + timeline anchor pure helpers"
```

---

## Task 2: Trim `AppState` + `TagFilterView` + timeline `ArticleReaderView`

**Files:**
- Modify: `Yana/Models/AppState.swift`
- Create: `Yana/Views/TagFilterView.swift`
- Modify: `Yana/Views/ArticleReaderView.swift` (full rewrite of the body; keep `ShareSheet`)

- [ ] **Step 1: Trim `AppState`**

Replace `Yana/Models/AppState.swift`:

```swift
import Foundation

@MainActor
@Observable
final class AppState {
    /// Index into the (filtered) timeline.
    var currentIndex: Int = 0
    var isUpdating = false
    var errorMessage: String?
    var showSettings = false
    var showFilter = false
}
```

- [ ] **Step 2: Create `TagFilterView`**

Create `Yana/Views/TagFilterView.swift`:

```swift
import SwiftData
import SwiftUI

/// Filter sheet: every tag plus an "Untagged" entry, each a toggle. All active by default.
/// Writes the disabled set / untagged flag to `AppSettings`.
struct TagFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var settings = AppSettings()
    /// Local mirror so toggles animate; synced to settings on change.
    @State private var disabled: Set<String> = []
    @State private var includeUntagged = true

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    toggleRow(tag.name, isActive: !disabled.contains(tag.name)) { active in
                        if active { disabled.remove(tag.name) } else { disabled.insert(tag.name) }
                        settings.disabledTagNames = disabled
                    }
                }
                toggleRow(String(localized: "Untagged"), isActive: includeUntagged) { active in
                    includeUntagged = active
                    settings.includeUntagged = active
                }
            }
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                disabled = settings.disabledTagNames
                includeUntagged = settings.includeUntagged
            }
        }
    }

    private func toggleRow(_ name: String, isActive: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(name, isOn: Binding(get: { isActive }, set: set))
    }
}
```

- [ ] **Step 3: Rewrite `ArticleReaderView` as the timeline**

Replace the entire contents of `Yana/Views/ArticleReaderView.swift`:

```swift
import SwiftData
import SwiftUI

struct ArticleReaderView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Article.date, order: .reverse) private var allArticles: [Article]
    @Query(filter: #Predicate<Tag> { $0.isBuiltIn }) private var builtInTags: [Tag]
    @State private var settings = AppSettings()

    @State private var dragOffset: CGFloat = 0
    @State private var shareURL: URL?
    @State private var isShowingShare = false

    /// The timeline after applying the persisted tag filter.
    private var articles: [Article] {
        TagFilter.apply(
            to: allArticles,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
    }

    private var currentArticle: Article? {
        guard appState.currentIndex >= 0, appState.currentIndex < articles.count else { return nil }
        return articles[appState.currentIndex]
    }

    private var starredTag: Tag? { builtInTags.first }

    var body: some View {
        NavigationStack {
            ZStack {
                if let article = currentArticle {
                    articleContent(article)
                        .offset(x: dragOffset)
                        .gesture(swipeGesture)
                        .animation(.interactiveSpring, value: dragOffset)
                } else {
                    ContentUnavailableView {
                        Label("No Articles", systemImage: "tray")
                    } description: {
                        Text("Add feeds in Configuration, then pull down to refresh.")
                    }
                }
            }
            .refreshable { await refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { appState.showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let article = currentArticle, let starredTag {
                        Button {
                            article.setStarred(!article.isStarred, using: starredTag)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: article.isStarred ? "star.fill" : "star")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { appState.showSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $appState.showSettings) { ConfigHubView() }
            .sheet(isPresented: $appState.showFilter) { TagFilterView() }
            .sheet(isPresented: $isShowingShare) {
                if let url = shareURL { ShareSheet(activityItems: [url]) }
            }
            .onAppear { restoreAnchor() }
            .onChange(of: appState.currentIndex) { _, _ in saveAnchor() }
        }
    }

    // MARK: - Anchor (position memory)

    private func restoreAnchor() {
        appState.currentIndex = TimelineAnchor.index(for: settings.timelineAnchorIdentifier, in: articles)
    }

    private func saveAnchor() {
        settings.timelineAnchorIdentifier = currentArticle?.identifier
    }

    // MARK: - Refresh (current article + whole timeline)

    private func refresh() async {
        let service = AggregationService(context: modelContext)
        if let article = currentArticle { await service.update(article: article) }
        await service.updateAll()
    }

    // MARK: - Article Content

    @ViewBuilder
    private func articleContent(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let feedTitle = article.feed?.name, !feedTitle.isEmpty {
                        Text(feedTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    if !article.author.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(article.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(article.date, style: .relative).font(.subheadline).foregroundStyle(.secondary)
                }

                Divider()

                ArticleWebView(htmlContent: article.content).frame(minHeight: 400)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { bottomBar(article) }
    }

    private func bottomBar(_ article: Article) -> some View {
        HStack {
            Spacer()
            if let url = URL(string: article.url) {
                Button { UIApplication.shared.open(url) } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                Button { shareURL = url; isShowingShare = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Swipe Gesture (bidirectional, no read state)

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onChanged { value in dragOffset = value.translation.width }
            .onEnded { value in
                let threshold: CGFloat = 100
                if value.translation.width < -threshold, appState.currentIndex < articles.count - 1 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = -UIScreen.main.bounds.width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex += 1
                        dragOffset = 0
                    }
                } else if value.translation.width > threshold, appState.currentIndex > 0 {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = UIScreen.main.bounds.width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        appState.currentIndex -= 1
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.interactiveSpring) { dragOffset = 0 }
                }
            }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 4: Run `xcodegen generate` and build**

Run: `xcodegen generate`
Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: endless timeline reader with tag filter, star, position memory, pull-to-refresh"
```

---

## Task 3: Localization sweep + manual smoke test

**Files:**
- Modify: `Yana/Resources/Localizable.xcstrings` (via Xcode string extraction)

- [ ] **Step 1: Build extracts strings**

`SWIFT_EMIT_LOC_STRINGS: YES` is set, so a build extracts new `String(localized:)` keys. Confirm the new reader strings (e.g. "Filter", "Untagged", "No Articles") are present in `Yana/Resources/Localizable.xcstrings` (English is the source — no translation needed).

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Manual smoke test (simulator)**

Use the `run` skill (or Xcode) to launch the app and verify (views have no unit tests):
- With no articles: the "No Articles" state shows; the filter button (top-left) opens the sheet listing tags + Untagged (all on); the gear opens Configuration.
- Pull-to-refresh runs without crashing (the stub touches `lastFetchedAt`).
- Insert a few sample articles (via a temporary debug action or by running a Phase 4 fetch later) and verify: swiping left/right moves through the timeline; the star button toggles `star`/`star.fill`; toggling a tag off in the filter hides matching articles; closing and relaunching restores the last position.

> Note: real articles only arrive once Phase 4 implements aggregation. Until then, the timeline is empty and the smoke test covers the empty-state, filter sheet, settings entry, and pull-to-refresh wiring.

- [ ] **Step 3: Commit any string-catalog changes**

```bash
git add -A
git commit -m "chore: extract Phase 3 localizable strings"
```

---

## Self-Review Notes

- **Spec coverage (Phase 3 scope):** tag filter + anchor helpers (T1), trimmed `AppState` + `TagFilterView` + timeline `ArticleReaderView` with position memory / star / pull-to-refresh (T2), localization + smoke (T3). Covers the "Home — endless timeline" spec section.
- **Type consistency:** uses Phase 2 symbols exactly — `Article.isStarred`/`setStarred(_:using:)`, `AggregationService(context:)`/`update(article:)`/`updateAll()`, `ConfigHubView`, and the `AppSettings` filter/anchor properties (`disabledTagNames`, `includeUntagged`, `timelineAnchorIdentifier`).
- **Dependency:** Phase 2 must be merged first; this plan assumes its symbols exist.
