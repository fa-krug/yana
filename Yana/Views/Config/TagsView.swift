import SwiftData
import SwiftUI

/// Tag CRUD: create / rename / recolor / delete / reorder. The built-in Starred tag is
/// locked (recolor only; no delete or rename).
struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var editingTag: Tag?
    @State private var isCreating = false
    @State private var offsetsToDelete: IndexSet?

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
                // Filter to only deletable (non-built-in) tags before prompting
                let deletable = offsets.filter { !tags[$0].isBuiltIn }
                guard !deletable.isEmpty else { return }
                offsetsToDelete = IndexSet(deletable)
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
            String(localized: "Delete Tag?"),
            isPresented: Binding(get: { offsetsToDelete != nil }, set: { if !$0 { offsetsToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let offsets = offsetsToDelete {
                    delete(offsets)
                }
                offsetsToDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                offsetsToDelete = nil
            }
        } message: {
            if let offsets = offsetsToDelete {
                let names = offsets.map { tags[$0].name }.joined(separator: ", ")
                Text(String(localized: "Delete \(names)? This cannot be undone."))
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            let tag = tags[index]
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
