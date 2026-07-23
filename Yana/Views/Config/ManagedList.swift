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

    /// When set, the list scrolls this row into view once on appear (used to reveal the
    /// reader's currently-selected article). Existing callers omit it (defaults to nil).
    var scrollToID: Item.ID? = nil

    @ViewBuilder var leadingActions: (Item) -> Leading
    @ViewBuilder var row: (Item) -> Row

    /// Guards the one-shot scroll to `scrollToID` so it lands exactly once per presentation,
    /// whether the target row is present on first appear or arrives once the `@Query` populates.
    @State private var didScrollToTarget = false

    private var reorderEnabled: Bool {
        onMove != nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// On Mac Catalyst the automatic placement crams the search field into the compact toolbar row
    /// next to the other bar buttons, which throws off the field's internal vertical text centering.
    /// A dedicated always-on drawer gives it a full-width row at its natural height. iOS keeps
    /// `.automatic` (the search field already renders correctly there).
    private static var searchPlacement: SearchFieldPlacement {
        #if targetEnvironment(macCatalyst)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
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
            .searchable(text: $searchText, placement: Self.searchPlacement, prompt: searchPrompt)
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
            // Land on the target row once. A synchronous scroll on first appear is dropped because
            // the List lays out its rows asynchronously, and the target may not even exist yet when
            // the @Query is still streaming — so retry across a few frames, and also re-arm when the
            // id transitions from nil to a value as rows arrive.
            .onAppear { scrollToTargetIfNeeded(proxy) }
            .onChange(of: scrollToID) { _, _ in scrollToTargetIfNeeded(proxy) }
        }
    }

    private func scrollToTargetIfNeeded(_ proxy: ScrollViewProxy) {
        guard let scrollToID, !didScrollToTarget else { return }
        didScrollToTarget = true
        Task { @MainActor in
            for delayMS in [0, 50, 150, 350] {
                try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                proxy.scrollTo(scrollToID, anchor: .center)
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
