import SwiftData
import SwiftUI

/// Searchable tag CRUD: create / rename / recolor / delete / reorder, built on `ManagedList`.
/// The built-in Starred tag is locked (recolor only; no delete or rename). Reorder is
/// suppressed while a search is active. Deletes go through a confirmation dialog.
struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var tagsToDelete: [Tag]?
    @State private var searchText = ""
    @State private var showingCreateTag = false

    private var filteredTags: [Tag] {
        NameSearch.filter(tags, query: searchText, name: \.name)
    }

    var body: some View {
        ManagedList(
            items: filteredTags,
            searchText: $searchText,
            searchPrompt: "Search tags",
            emptyTitle: "No Tags",
            emptyIcon: "tag",
            emptyDescription: "Tap + to create your first tag.",
            onDelete: { offsets in
                // Resolve Tag objects immediately so stale indices can't cause wrong-delete or crash
                let deletable = offsets.compactMap { filteredTags[$0].isBuiltIn ? nil : filteredTags[$0] }
                guard !deletable.isEmpty else { return }
                tagsToDelete = deletable
            },
            onMove: move
        ) { tag in
            NavigationLink {
                TagEditorView(tag: tag)
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((Color(hex: tag.colorHex) ?? .accentColor).gradient)
                        .frame(width: 22, height: 22)
                    Text(tag.name)
                    if tag.isBuiltIn {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("System tag"))
                    }
                    Spacer()
                }
            }
            .tint(.primary)
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreateTag = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .sheet(isPresented: $showingCreateTag) {
            NavigationStack { TagEditorView(tag: nil) }
        }
        .alert(
            (tagsToDelete?.count ?? 0) == 1
                ? String(localized: "Delete Tag?")
                : String(localized: "Delete Tags?"),
            isPresented: Binding(get: { tagsToDelete != nil }, set: { if !$0 { tagsToDelete = nil } })
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let resolved = tagsToDelete {
                    delete(resolved)
                    Haptics.notify(.success)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if let resolved = tagsToDelete {
                let names = resolved.map(\.name).joined(separator: ", ")
                Text(String(localized: "Delete \(names)? This cannot be undone."))
            }
        }
    }

    private func delete(_ resolved: [Tag]) {
        for tag in resolved {
            guard !tag.isBuiltIn else { continue } // Starred is locked
            modelContext.delete(tag)
        }
        try? modelContext.save()
        ConfigSyncService.shared.requestPush()
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        var reordered = tags
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, tag) in reordered.enumerated() { tag.sortOrder = index }
        try? modelContext.save()
        ConfigSyncService.shared.requestPush()
    }
}
