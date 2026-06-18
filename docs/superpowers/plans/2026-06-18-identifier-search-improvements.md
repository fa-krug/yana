# Identifier Search Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the subreddit / YouTube identifier picker preload an initial list, search live as you type, look like the app's other lists, and use an icon Cancel button.

**Architecture:** `IdentifierSearchModel` (the existing `@Observable` view-model) gains a preload closure and restructured `IdentifierSearchRow` (structured `title`/`subtitle` instead of one prebuilt `label`). `RedditClient` gains a `popularSubreddits` static for the preload. `IdentifierSearchView` debounces query changes (~300 ms) into `model.search`, preloads on appear via `.task`, renders two-line rows, and uses an `xmark` icon for Cancel.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`import Testing`), XcodeGen.

## Global Constraints

- Platform: iOS 26.0+; Swift 6 strict concurrency; `@MainActor` on view-models and tests.
- Source language English (`en`); supported languages `en`, `de`. Every new/changed user-facing string MUST be added to `Yana/Resources/Localizable.xcstrings` with a German translation marked `"state" : "translated"`. German follows Apple style (infinitive for actions, no "Du"/"Sie").
- Tests use Swift Testing (`@Test`, `#expect`) under `@MainActor` where they touch the model.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build` / `… test`.
- No new files (keeps the XcodeGen project unchanged): the subscriber-count helper lives at the top of `Yana/Views/Config/IdentifierSearchView.swift`.

---

### Task 1: Compact subscriber-count formatter

**Files:**
- Modify: `Yana/Views/Config/IdentifierSearchView.swift` (add `SubscriberCount` enum at top, below `import SwiftUI`)
- Test: `YanaTests/IdentifierSearchTests.swift`

**Interfaces:**
- Produces: `enum SubscriberCount { static func compact(_ n: Int) -> String }` — `7937468 → "7.9M"`, `411321 → "411K"`, `2360328 → "2.4M"`, `1500 → "1.5K"`, `999 → "999"`. Rule: values ≥ 1,000,000 scale to `M`, ≥ 1,000 scale to `K`; the scaled number shows one decimal when < 10, no decimal when ≥ 10, and a trailing `.0` is dropped.

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/IdentifierSearchTests.swift` inside the `IdentifierSearchTests` suite:

```swift
    @Test func subscriberCompactFormatting() {
        #expect(SubscriberCount.compact(7_937_468) == "7.9M")
        #expect(SubscriberCount.compact(2_360_328) == "2.4M")
        #expect(SubscriberCount.compact(411_321) == "411K")
        #expect(SubscriberCount.compact(30_251) == "30K")
        #expect(SubscriberCount.compact(1_500) == "1.5K")
        #expect(SubscriberCount.compact(999) == "999")
        #expect(SubscriberCount.compact(0) == "0")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/IdentifierSearchTests/subscriberCompactFormatting`
Expected: FAIL — `cannot find 'SubscriberCount' in scope`.

- [ ] **Step 3: Add the implementation**

At the top of `Yana/Views/Config/IdentifierSearchView.swift`, right after `import SwiftUI`:

```swift
/// Formats a subscriber/member count compactly (e.g. 7937468 → "7.9M", 411321 → "411K").
enum SubscriberCount {
    static func compact(_ n: Int) -> String {
        func scale(_ value: Double, _ suffix: String) -> String {
            let s = value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
            let trimmed = s.hasSuffix(".0") ? String(s.dropLast(2)) : s
            return trimmed + suffix
        }
        switch n {
        case 1_000_000...: return scale(Double(n) / 1_000_000, "M")
        case 1_000...: return scale(Double(n) / 1_000, "K")
        default: return "\(n)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/IdentifierSearchTests/subscriberCompactFormatting`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/IdentifierSearchView.swift YanaTests/IdentifierSearchTests.swift
git commit -m "feat(search): add compact subscriber-count formatter"
```

---

### Task 2: Reddit popular endpoint + raise result caps to 25

**Files:**
- Modify: `Yana/Aggregators/Concrete/RedditClient.swift` (add `popularSubreddits`; change `searchSubreddits` limit `10` → `25`)
- Modify: `Yana/Aggregators/Concrete/YouTubeClient.swift:93` (change `searchChannels` `maxResults` `"10"` → `"25"`)
- Test: `YanaTests/RedditClientTests.swift`

**Interfaces:**
- Produces: `static func RedditClient.popularSubreddits(credentials: AggregatorCredentials, userAgent: String, fetch: @escaping Fetch = …) async -> [RedditSubredditResult]` — fetches `https://oauth.reddit.com/subreddits/popular.json?limit=25&raw_json=1`, returns mapped `RedditSubredditResult` with empty `displayName` filtered out, or `[]` on any failure / missing credentials.
- Consumes: existing private `RedditSubredditListing` decoder, private `authorizedGET`, and `RedditSubredditResult` (`displayName`, `title`, `subscribers`).

- [ ] **Step 1: Write the failing test**

Add to `YanaTests/RedditClientTests.swift` inside the `RedditClientTests` suite. Place this `popularJSON` constant next to the other JSON constants:

```swift
    private let popularJSON = """
    {"data":{"children":[
      {"data":{"display_name":"funny","title":"funny","subscribers":40000000}},
      {"data":{"display_name":"","title":"blank","subscribers":1}},
      {"data":{"display_name":"AskReddit","title":"Ask Reddit","subscribers":45000000}}
    ]}}
    """
```

And add the test (uses its own routed client so it doesn't depend on the suite's shared `client()`):

```swift
    @Test func popularSubredditsParsedAndFiltered() async {
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret")
        let results = await RedditClient.popularSubreddits(
            credentials: creds, userAgent: "Yana/1.0") { request in
                let url = request.url!.absoluteString
                if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
                return Data(self.popularJSON.utf8)
            }
        // Blank display_name is filtered out.
        #expect(results.map(\.displayName) == ["funny", "AskReddit"])
        #expect(results.first?.subscribers == 40_000_000)
    }
```

Note: confirm `AggregatorCredentials` has accessible `redditClientID` / `redditClientSecret` initializer parameters by checking `Yana/Aggregators/Aggregator.swift`. If the memberwise init is not usable that way, construct via the same pattern the existing tests use (e.g. set the properties on a `var creds = AggregatorCredentials()`).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests/popularSubredditsParsedAndFiltered`
Expected: FAIL — `type 'RedditClient' has no member 'popularSubreddits'`.

- [ ] **Step 3: Add `popularSubreddits` and raise the search limit**

In `Yana/Aggregators/Concrete/RedditClient.swift`, add directly after the `searchSubreddits` method (before `// MARK: - Helpers`):

```swift
    static func popularSubreddits(credentials: AggregatorCredentials, userAgent: String,
                                  fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [RedditSubredditResult] {
        guard let id = credentials.redditClientID, let secret = credentials.redditClientSecret else { return [] }
        let client = RedditClient(clientID: id, clientSecret: secret, userAgent: userAgent, fetch: fetch)
        guard let url = URL(string: "https://oauth.reddit.com/subreddits/popular.json?limit=25&raw_json=1"),
              let data = try? await client.authorizedGET(url),
              let listing = try? JSONDecoder().decode(RedditSubredditListing.self, from: data) else { return [] }
        return listing.data.children.map {
            RedditSubredditResult(displayName: $0.data.displayName ?? "",
                                  title: $0.data.title ?? "",
                                  subscribers: $0.data.subscribers ?? 0)
        }.filter { !$0.displayName.isEmpty }
    }
```

In the same file, in `searchSubreddits`, change the search URL limit from `10` to `25`:

```swift
              let url = URL(string: "https://oauth.reddit.com/subreddits/search.json?q=\(q)&limit=25&raw_json=1"),
```

- [ ] **Step 4: Raise the YouTube search cap**

In `Yana/Aggregators/Concrete/YouTubeClient.swift`, in `searchChannels`, change the search call's `maxResults` from `"10"` to `"25"`:

```swift
        guard let data = try? await client.get("search", ["part": "id", "q": query, "type": "channel", "maxResults": "25"]),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/RedditClientTests`
Expected: PASS (including the existing RedditClient tests).

- [ ] **Step 6: Commit**

```bash
git add Yana/Aggregators/Concrete/RedditClient.swift Yana/Aggregators/Concrete/YouTubeClient.swift YanaTests/RedditClientTests.swift
git commit -m "feat(search): add popular-subreddits endpoint; raise result caps to 25"
```

---

### Task 3: Restructure the model — structured rows, preload, debounce-safe search

**Files:**
- Modify: `Yana/Views/Config/IdentifierSearchView.swift` (`IdentifierSearchRow`, `IdentifierSearchModel`)
- Test: `YanaTests/IdentifierSearchTests.swift`

**Interfaces:**
- Produces:
  - `struct IdentifierSearchRow { var value: String; var title: String; var subtitle: String; var id: String { value } }`
  - `IdentifierSearchModel` new/changed members: `var didPreload: Bool`; `func preload() async`; `func search(_ query: String) async` (now maps into structured rows and restores the preloaded list on empty query); new init parameter `redditPopular: (() async -> [RedditSubredditResult])? = nil` (defaults to `RedditClient.popularSubreddits(...)`).
- Consumes: `SubscriberCount.compact` (Task 1), `RedditClient.popularSubreddits` (Task 2), existing `RedditSubredditResult`, `YouTubeChannelResult`, `AggregatorIdentifierKind`.

- [ ] **Step 1: Update the existing model tests and add new ones**

Replace the entire body of `YanaTests/IdentifierSearchTests.swift`'s three existing label-based tests and add preload coverage. The `subscriberCompactFormatting` test from Task 1 stays. The suite becomes:

```swift
import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("IdentifierSearch")
struct IdentifierSearchTests {
    @Test func subscriberCompactFormatting() {
        #expect(SubscriberCount.compact(7_937_468) == "7.9M")
        #expect(SubscriberCount.compact(2_360_328) == "2.4M")
        #expect(SubscriberCount.compact(411_321) == "411K")
        #expect(SubscriberCount.compact(30_251) == "30K")
        #expect(SubscriberCount.compact(1_500) == "1.5K")
        #expect(SubscriberCount.compact(999) == "999")
        #expect(SubscriberCount.compact(0) == "0")
    }

    @Test func redditResultsMapToStructuredRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in
                [RedditSubredditResult(displayName: "swift", title: "Swift", subscribers: 12345)]
            }, youtubeSearch: { _ in [] }, redditPopular: { [] })
        await model.search("swi")
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.value == "swift")
        #expect(model.rows.first?.title == "r/swift")
        #expect(model.rows.first?.subtitle.contains("Swift") == true)
        #expect(model.rows.first?.subtitle.contains("12K") == true)
    }

    @Test func youtubeResultsMapToStructuredRows() async {
        let model = IdentifierSearchModel(kind: .youtubeChannel, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [] },
            youtubeSearch: { _ in [YouTubeChannelResult(channelID: "UCabc", title: "Cool", handle: "@cool")] },
            redditPopular: { [] })
        await model.search("cool")
        #expect(model.rows.first?.value == "UCabc")
        #expect(model.rows.first?.title == "Cool")
        #expect(model.rows.first?.subtitle == "@cool")
    }

    @Test func youtubeFallsBackToChannelIDWhenNoHandle() async {
        let model = IdentifierSearchModel(kind: .youtubeChannel, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [] },
            youtubeSearch: { _ in [YouTubeChannelResult(channelID: "UCxyz", title: "NoHandle", handle: nil)] },
            redditPopular: { [] })
        await model.search("no")
        #expect(model.rows.first?.subtitle == "UCxyz")
    }

    @Test func preloadPopulatesRowsForSubreddit() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [] }, youtubeSearch: { _ in [] },
            redditPopular: { [RedditSubredditResult(displayName: "funny", title: "Funny", subscribers: 40_000_000)] })
        await model.preload()
        #expect(model.didPreload)
        #expect(model.rows.first?.title == "r/funny")
        #expect(model.rows.first?.subtitle.contains("40M") == true)
    }

    @Test func clearingQueryRestoresPreloadedRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [RedditSubredditResult(displayName: "swift", title: "Swift", subscribers: 1)] },
            youtubeSearch: { _ in [] },
            redditPopular: { [RedditSubredditResult(displayName: "funny", title: "Funny", subscribers: 5)] })
        await model.preload()
        await model.search("swift")
        #expect(model.rows.first?.value == "swift")
        await model.search("")
        #expect(model.rows.first?.value == "funny")   // restored, not empty
        #expect(model.hasSearched == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/IdentifierSearchTests`
Expected: FAIL — `extra argument 'redditPopular' in call` and `value of type 'IdentifierSearchRow' has no member 'title'`.

- [ ] **Step 3: Rewrite `IdentifierSearchRow` and `IdentifierSearchModel`**

In `Yana/Views/Config/IdentifierSearchView.swift`, replace the `IdentifierSearchRow` struct and the entire `IdentifierSearchModel` class (keep the `SubscriberCount` enum from Task 1 above them) with:

```swift
/// A pickable search result row (value is saved to the feed identifier).
struct IdentifierSearchRow: Identifiable, Sendable {
    var value: String
    var title: String
    var subtitle: String
    var id: String { value }
}

/// Testable search state: preloads an initial list (popular subreddits) and maps
/// reddit/youtube live-search results into structured rows. The search/preload closures
/// default to the real APIs but are injectable for tests.
@MainActor
@Observable
final class IdentifierSearchModel {
    let kind: AggregatorIdentifierKind
    var rows: [IdentifierSearchRow] = []
    var isSearching = false
    var hasSearched = false
    var didPreload = false

    private var preloadedRows: [IdentifierSearchRow] = []
    private var searchGeneration = 0

    private let redditSearch: (String) async -> [RedditSubredditResult]
    private let youtubeSearch: (String) async -> [YouTubeChannelResult]
    private let redditPopular: () async -> [RedditSubredditResult]

    init(kind: AggregatorIdentifierKind,
         credentials: AggregatorCredentials,
         userAgent: String,
         apiKey: String? = nil,
         redditSearch: ((String) async -> [RedditSubredditResult])? = nil,
         youtubeSearch: ((String) async -> [YouTubeChannelResult])? = nil,
         redditPopular: (() async -> [RedditSubredditResult])? = nil) {
        self.kind = kind
        self.redditSearch = redditSearch ?? { query in
            await RedditClient.searchSubreddits(query: query, credentials: credentials, userAgent: userAgent)
        }
        self.youtubeSearch = youtubeSearch ?? { query in
            await YouTubeClient.searchChannels(query: query, apiKey: apiKey ?? "")
        }
        self.redditPopular = redditPopular ?? {
            await RedditClient.popularSubreddits(credentials: credentials, userAgent: userAgent)
        }
    }

    /// Loads the initial list once. Subreddits preload popular communities; YouTube has no
    /// query-less endpoint, so it stays empty until the user types.
    func preload() async {
        guard !didPreload else { return }
        didPreload = true
        guard kind == .subreddit else { return }
        isSearching = true
        preloadedRows = (await redditPopular()).map(subredditRow)
        isSearching = false
        // Only adopt the preloaded list if the user hasn't already typed something.
        if rows.isEmpty && !hasSearched { rows = preloadedRows }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { rows = preloadedRows; hasSearched = false; return }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        let mapped: [IdentifierSearchRow]
        switch kind {
        case .subreddit:
            mapped = (await redditSearch(trimmed)).map(subredditRow)
        case .youtubeChannel:
            mapped = (await youtubeSearch(trimmed)).map(youtubeRow)
        default:
            mapped = []
        }
        // A newer keystroke superseded this search while it was in flight — drop the result.
        guard generation == searchGeneration else { return }
        rows = mapped
        isSearching = false
        hasSearched = true
    }

    private func subredditRow(_ r: RedditSubredditResult) -> IdentifierSearchRow {
        let count = String(localized: "\(SubscriberCount.compact(r.subscribers)) subscribers")
        let subtitle = r.title.isEmpty ? count : "\(r.title) · \(count)"
        return IdentifierSearchRow(value: r.displayName, title: "r/\(r.displayName)", subtitle: subtitle)
    }

    private func youtubeRow(_ r: YouTubeChannelResult) -> IdentifierSearchRow {
        IdentifierSearchRow(value: r.channelID, title: r.title, subtitle: r.handle ?? r.channelID)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/IdentifierSearchTests`
Expected: PASS.

Note: the new `"%@ subscribers"` string will be flagged by the build as missing a German translation only at catalog-extraction time; it is added in Task 4. Tests pass regardless because `String(localized:)` falls back to the key.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/IdentifierSearchView.swift YanaTests/IdentifierSearchTests.swift
git commit -m "feat(search): preload list, structured rows, debounce-safe search in model"
```

---

### Task 4: View — debounced live search, preload on appear, styled rows, icon Cancel + localization

**Files:**
- Modify: `Yana/Views/Config/IdentifierSearchView.swift` (`IdentifierSearchView` body)
- Modify: `Yana/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `IdentifierSearchModel.preload()`, `.search(_:)`, `.rows` (`title`/`subtitle`), `.isSearching`, `.hasSearched` (Task 3).

- [ ] **Step 1: Rewrite the `IdentifierSearchView` body**

In `Yana/Views/Config/IdentifierSearchView.swift`, replace the `IdentifierSearchView` struct's `body` (keep the `init` unchanged) and add a `searchTask` state property. The struct becomes:

```swift
/// A sheet that searches subreddits / YouTube channels and lets the user pick one.
struct IdentifierSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: IdentifierSearchModel
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    let onPick: (String) -> Void

    init(kind: AggregatorIdentifierKind, onPick: @escaping (String) -> Void) {
        let creds = AggregatorCredentials.resolved()
        let apiKey = creds.youtubeAPIKey
        _model = State(initialValue: IdentifierSearchModel(
            kind: kind, credentials: creds, userAgent: AppSettings().redditUserAgent, apiKey: apiKey))
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            List(model.rows) { row in
                Button {
                    onPick(row.value)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.headline)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if model.isSearching && model.rows.isEmpty {
                    ProgressView()
                } else if model.rows.isEmpty {
                    if model.hasSearched {
                        ContentUnavailableView(
                            "No Results", systemImage: "magnifyingglass",
                            description: Text("No matches found. Check the search term, "
                                + "and that the required API key is set in Settings."))
                    } else if model.kind == .youtubeChannel {
                        ContentUnavailableView(
                            "Search Channels", systemImage: "magnifyingglass",
                            description: Text("Enter a channel name to search."))
                    } else {
                        ContentUnavailableView("Search", systemImage: "magnifyingglass")
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query)
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await model.search(newValue)
                }
            }
            .onSubmit(of: .search) {
                searchTask?.cancel()
                Task { await model.search(query) }
            }
            .task { await model.preload() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add the localized strings**

Open `Yana/Resources/Localizable.xcstrings`. Add (or confirm) entries for the new/changed keys with German translations marked `"state" : "translated"`:

- `"%@ subscribers"` → de: `"%@ Abonnenten"`
- `"Search Channels"` → de: `"Kanäle suchen"`
- `"Enter a channel name to search."` → de: `"Kanalnamen zum Suchen eingeben."`

`"Search"`, `"No Results"`, the no-results description, and `"Cancel"` already exist in the catalog (verify they remain marked translated). Edit the JSON so each new key looks like the surrounding entries, e.g.:

```json
    "%@ subscribers" : {
      "localizations" : {
        "de" : {
          "stringUnit" : { "state" : "translated", "value" : "%@ Abonnenten" }
        }
      }
    },
```

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/IdentifierSearchTests -only-testing:YanaTests/RedditClientTests`
Expected: PASS.

- [ ] **Step 4: Manual verification (simulator)**

Open the app → add/edit a Reddit feed → tap the search (magnifying glass) next to the subreddit field. Confirm:
- The list preloads popular subreddits on open (requires Reddit API credentials set in Settings; without them the list is empty — expected).
- Typing filters live (no enter needed); clearing the field restores the popular list.
- Rows show `r/<name>` bold with `<title> · <count> subscribers` beneath.
- The Cancel control is an `xmark` icon.
Repeat for a YouTube feed: opens with the "Search Channels" prompt, typing returns up to 25 channels styled the same way.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Config/IdentifierSearchView.swift Yana/Resources/Localizable.xcstrings
git commit -m "feat(search): debounced live search, preload on appear, styled rows, icon Cancel"
```

---

## Self-Review Notes

- **Spec coverage:** preload (Task 2 + 3), debounced live search (Task 3 model + Task 4 view), styling like other lists (Task 4 two-line rows), Cancel→icon (Task 4), both title+subscriber count in subtitle (Task 3 `subredditRow`), YouTube 25 entries (Task 2), localization (Task 4). All covered.
- **Type consistency:** `IdentifierSearchRow` uses `value`/`title`/`subtitle` everywhere; `redditPopular` closure name consistent across model + tests; `SubscriberCount.compact` signature consistent.
- **Verification gap:** the SwiftUI view body has no unit test (standard for this codebase); covered by build + manual steps in Task 4.
