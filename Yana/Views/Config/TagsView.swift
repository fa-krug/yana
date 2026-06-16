import SwiftData
import SwiftUI

struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var editingTag: Tag?
    @State private var isCreating = false
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
            onDelete: delete,
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
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            let tag = filteredTags[index]
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
