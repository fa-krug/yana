import SwiftData
import SwiftUI

/// Searchable tag CRUD: create / rename / recolor / delete / reorder, built on `ManagedList`.
/// The built-in Starred tag is locked (recolor only; no delete or rename). Reorder is
/// suppressed while a search is active. Deletes go through a confirmation dialog.
struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var editingTag: Tag?
    @State private var isCreating = false
    @State private var tagsToDelete: [Tag]?
    @State private var searchText = ""

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
            Button {
                editingTag = tag
            } label: {
                HStack {
                    Circle().fill(Color(hex: tag.colorHex) ?? .accentColor).frame(width: 14, height: 14)
                    Text(tag.name)
                    if tag.isBuiltIn {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .tint(.primary)
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .sheet(item: $editingTag) { tag in TagEditorView(tag: tag) }
        .sheet(isPresented: $isCreating) { TagEditorView(tag: nil) }
        .confirmationDialog(
            (tagsToDelete?.count ?? 0) == 1
                ? String(localized: "Delete Tag?")
                : String(localized: "Delete Tags?"),
            isPresented: Binding(get: { tagsToDelete != nil }, set: { if !$0 { tagsToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let resolved = tagsToDelete {
                    delete(resolved)
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
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        var reordered = tags
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, tag) in reordered.enumerated() { tag.sortOrder = index }
        try? modelContext.save()
    }
}
