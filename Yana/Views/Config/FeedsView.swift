import SwiftData
import SwiftUI

/// Flat list of feeds with tag chips, last-fetched time, error badge, enable state,
/// per-feed update, and article count. Add / delete; "Update all".
struct FeedsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Feed.name) private var feeds: [Feed]
    @State private var isUpdating = false

    var body: some View {
        List {
            ForEach(feeds) { feed in
                NavigationLink {
                    FeedEditorView(feed: feed)
                } label: {
                    row(feed)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelContext.delete(feed)
                        try? modelContext.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await updateOne(feed) }
                    } label: {
                        Label("Update", systemImage: "arrow.clockwise")
                    }
                    .tint(.blue)
                    .disabled(isUpdating)
                }
            }
        }
        .navigationTitle("Feeds")
        .overlay {
            if feeds.isEmpty {
                ContentUnavailableView("No Feeds", systemImage: "list.bullet.rectangle",
                                       description: Text("Tap + to add your first feed."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    FeedEditorView(feed: nil)
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Update All") { Task { await updateAll() } }
                    .disabled(isUpdating || feeds.isEmpty)
            }
        }
    }

    private func row(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feed.name).font(.headline)
                if !feed.enabled {
                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                }
                if feed.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            HStack(spacing: 6) {
                Text(feed.type.displayName)
                Text("· \(feed.articles.count) articles")
                if let fetched = feed.lastFetchedAt {
                    Text("· \(fetched, style: .relative) ago")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !feed.tags.isEmpty {
                Text(feed.tags.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        await AggregationService(context: modelContext).updateAll()
    }

    private func updateOne(_ feed: Feed) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        await AggregationService(context: modelContext).update(feed: feed)
    }
}
