import SwiftUI

/// Reusable searchable + editable list used by the config hub's Feeds, Tags, and Articles
/// screens. Owns the common chrome — `.searchable`, delete (swipe + edit-mode), optional
/// reorder, and a search-aware empty state. Each screen keeps its own `@Query`, computes the
/// filtered `items`, and passes a row builder plus edit closures.
///
/// Reorder and search don't compose (moving rows within a filtered subset is ambiguous), so
/// `onMove` is suppressed while a search is active.
struct ManagedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var searchText: String
    var searchPrompt: LocalizedStringKey

    var emptyTitle: LocalizedStringKey
    var emptyIcon: String
    var emptyDescription: LocalizedStringKey

    var onDelete: ((IndexSet) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil

    @ViewBuilder var row: (Item) -> Row

    private var reorderEnabled: Bool {
        onMove != nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            ForEach(items) { item in
                row(item)
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
