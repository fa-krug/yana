import SwiftUI

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
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            rows = preloadedRows
            hasSearched = false
            isSearching = false
            return
        }
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
        // A newer search (including a field-clear) superseded this one while it was in flight.
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
            .animation(CrossFade.animation, value: model.rows.map(\.id))
            .overlay {
                if model.isSearching && model.rows.isEmpty {
                    List(0..<8, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("r/placeholdername").font(.headline)
                            Text("Placeholder subtitle · 12K subscribers")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                    .skeleton(active: true)
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
