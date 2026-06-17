import SwiftUI

/// Reusable searchable + editable list used by the config hub's Feeds, Tags, and Articles
/// screens. Owns the common chrome — `.searchable`, trailing delete (swipe + edit-mode),
/// an optional leading-edge swipe action per row, optional reorder, and a search-aware
/// empty state. Each screen keeps its own `@Query`, computes the filtered `items`, and
/// passes a row builder plus edit closures. Callers that need no leading action use the
/// `EmptyView` convenience initializer.
///
/// Reorder and search don't compose (moving rows within a filtered subset is ambiguous), so
/// `onMove` is suppressed while a search is active.
struct ManagedList<Item: Identifiable, Row: View, Leading: View>: View {
    let items: [Item]
    @Binding var searchText: String
    var searchPrompt: LocalizedStringKey

    var emptyTitle: LocalizedStringKey
    var emptyIcon: String
    var emptyDescription: LocalizedStringKey

    var onDelete: ((IndexSet) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil

    @ViewBuilder var leadingActions: (Item) -> Leading
    @ViewBuilder var row: (Item) -> Row

    private var reorderEnabled: Bool {
        onMove != nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            ForEach(items) { item in
                row(item)
                    .swipeActions(edge: .leading) {
                        leadingActions(item)
                    }
            }
            .onDelete(perform: onDelete)
            .onMove(perform: reorderEnabled ? onMove : nil)
        }
        .searchable(text: $searchText, prompt: searchPrompt)
        .overlay {
            if items.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptyIcon,
                                           description: Text(emptyDescription))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }
}

extension ManagedList where Leading == EmptyView {
    init(
        items: [Item],
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey,
        emptyTitle: LocalizedStringKey,
        emptyIcon: String,
        emptyDescription: LocalizedStringKey,
        onDelete: ((IndexSet) -> Void)? = nil,
        onMove: ((IndexSet, Int) -> Void)? = nil,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.items = items
        self._searchText = searchText
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.emptyIcon = emptyIcon
        self.emptyDescription = emptyDescription
        self.onDelete = onDelete
        self.onMove = onMove
        self.leadingActions = { _ in EmptyView() }
        self.row = row
    }
}
