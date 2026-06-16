import SwiftUI

/// A pickable search result row (value is saved to the feed identifier).
struct IdentifierSearchRow: Identifiable, Sendable {
    var value: String
    var label: String
    var id: String { value }
}

/// Testable search state: maps reddit/youtube live-search results into rows.
/// The two search closures default to the real static searches but are injectable for tests.
@MainActor
@Observable
final class IdentifierSearchModel {
    let kind: AggregatorIdentifierKind
    var rows: [IdentifierSearchRow] = []
    var isSearching = false
    var hasSearched = false

    private let redditSearch: (String) async -> [RedditSubredditResult]
    private let youtubeSearch: (String) async -> [YouTubeChannelResult]

    init(kind: AggregatorIdentifierKind,
         credentials: AggregatorCredentials,
         userAgent: String,
         apiKey: String? = nil,
         redditSearch: ((String) async -> [RedditSubredditResult])? = nil,
         youtubeSearch: ((String) async -> [YouTubeChannelResult])? = nil) {
        self.kind = kind
        self.redditSearch = redditSearch ?? { query in
            await RedditClient.searchSubreddits(query: query, credentials: credentials, userAgent: userAgent)
        }
        self.youtubeSearch = youtubeSearch ?? { query in
            await YouTubeClient.searchChannels(query: query, apiKey: apiKey ?? "")
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { rows = []; hasSearched = false; return }
        isSearching = true
        defer { isSearching = false }
        switch kind {
        case .subreddit:
            rows = (await redditSearch(trimmed)).map {
                IdentifierSearchRow(value: $0.displayName,
                                    label: "r/\($0.displayName) — \($0.title) (\($0.subscribers) subs)")
            }
        case .youtubeChannel:
            rows = (await youtubeSearch(trimmed)).map { result in
                IdentifierSearchRow(value: result.channelID,
                                    label: result.handle.map { "\(result.title) (\($0))" } ?? "\(result.title) (\(result.channelID))")
            }
        default:
            rows = []
        }
        hasSearched = true
    }
}

/// A sheet that searches subreddits / YouTube channels and lets the user pick one.
struct IdentifierSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: IdentifierSearchModel
    @State private var query = ""
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
                    Text(row.label)
                }
            }
            .overlay {
                if model.isSearching {
                    ProgressView()
                } else if model.rows.isEmpty {
                    if model.hasSearched {
                        ContentUnavailableView(
                            "No Results", systemImage: "magnifyingglass",
                            description: Text("No matches found. Check the search term, "
                                + "and that the required API key is set in Settings."))
                    } else {
                        ContentUnavailableView("Search", systemImage: "magnifyingglass")
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query)
            .onSubmit(of: .search) { Task { await model.search(query) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
