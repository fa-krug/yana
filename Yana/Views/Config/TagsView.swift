import SwiftData
import SwiftUI

/// Tag CRUD: create / rename / recolor / delete / reorder. The built-in Starred tag is
/// locked (recolor only; no delete or rename).
struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var editingTag: Tag?
    @State private var isCreating = false
    @State private var tagsToDelete: [Tag]?

    var body: some View {
        List {
            ForEach(tags) { tag in
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
            .onDelete { offsets in
                // Resolve Tag objects immediately so stale indices can't cause wrong-delete or crash
                let deletable = offsets.compactMap { tags[$0].isBuiltIn ? nil : tags[$0] }
                guard !deletable.isEmpty else { return }
                tagsToDelete = deletable
            }
            .onMove(perform: move)
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
