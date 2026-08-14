import SwiftUI

/// Search field placement shared by every `ManagedList` caller. Factored out as a free enum
/// (rather than living on `ManagedList` itself) so a caller can attach `.searchable()` — see
/// `ManagedList`'s doc comment for why callers now own that modifier — without having to spell out
/// `ManagedList`'s generic parameters just to reach a placement constant.
enum ManagedListSearch {
    /// On Mac Catalyst the automatic placement crams the search field into the compact toolbar row
    /// next to the other bar buttons, which throws off the field's internal vertical text centering.
    /// A dedicated always-on drawer gives it a full-width row at its natural height. iOS keeps
    /// `.automatic` (the search field already renders correctly there).
    static var placement: SearchFieldPlacement {
        #if targetEnvironment(macCatalyst)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }
}

/// Reusable editable list, currently used only by `ArticleListView`. Owns the common chrome —
/// trailing delete (swipe + edit-mode), an optional leading-edge swipe action per row, optional
/// reorder, and a search-aware empty state. The caller computes the filtered `items` and passes a
/// row builder plus edit closures. Callers that need no leading action use the `EmptyView`
/// convenience initializer.
///
/// Reorder and search don't compose (moving rows within a filtered subset is ambiguous), so
/// `onMove` is suppressed while a search is active.
///
/// **Callers attach `.searchable()` themselves, outside this view** — it is deliberately not
/// applied here, so a caller that resets this view's identity (e.g. via `.id()`) can keep
/// `.searchable()` on a stable ancestor instead; `.id()` forces full identity teardown of
/// everything inside it, and `.searchable()`'s backing search controller is no exception — the
/// *text* survives (it's a `@Binding` into the stable parent's `@State`), but first-responder
/// status/cursor/keyboard do not, silently dropping focus out of the search field mid-typing.
/// `searchText` is still threaded through here for the empty-state copy and to gate reorder.
struct ManagedList<Item: Identifiable, Row: View, Leading: View>: View {
    let items: [Item]
    @Binding var searchText: String

    var emptyTitle: LocalizedStringKey
    var emptyIcon: String
    var emptyDescription: LocalizedStringKey

    var onDelete: ((IndexSet) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil

    /// When set, the list opens showing this row (used to reveal the reader's currently-selected
    /// article). Existing callers omit it (defaults to nil).
    var scrollToID: Item.ID? = nil

    @ViewBuilder var leadingActions: (Item) -> Leading
    @ViewBuilder var row: (Item) -> Row

    /// Guards the one-shot scroll to `scrollToID` so it lands exactly once per presentation,
    /// whether the target row is present on first appear or arrives once the items populate.
    @State private var didScrollToTarget = false

    /// Whether the rows are visible yet. Starts `false` whenever there's a `scrollToID` to land on,
    /// so the scroll happens behind a blank list instead of in front of the user -- see
    /// `scrollToTargetIfNeeded`. Seeded in `init`, since a value assigned from `onAppear` would
    /// already be one frame too late.
    @State private var revealed: Bool

    /// Set once a `scrollTo` has been issued *and* the layout pass after it has run. The reveal
    /// condition ignores anything the target row reported before that: a target near the top is
    /// realized before any scrolling, and revealing on that first report would show it in its
    /// pre-scroll place and let the centering scroll shift it in front of the user.
    @State private var scrollHasSettled = false

    /// The target row's last reported frame, kept so the reveal can also be re-evaluated when
    /// `scrollHasSettled` flips — in a list short enough that the scroll moves nothing, the row
    /// reports its position once and never again.
    @State private var targetRowFrame: CGRect?

    /// The list's own frame, against which the target row's frame is tested for on-screen-ness.
    @State private var listFrame: CGRect = .zero

    /// Spelled out (no memberwise init) only so `revealed` can be seeded from `scrollToID` at
    /// view-value construction time — see that property.
    init(
        items: [Item],
        searchText: Binding<String>,
        emptyTitle: LocalizedStringKey,
        emptyIcon: String,
        emptyDescription: LocalizedStringKey,
        onDelete: ((IndexSet) -> Void)? = nil,
        onMove: ((IndexSet, Int) -> Void)? = nil,
        scrollToID: Item.ID? = nil,
        @ViewBuilder leadingActions: @escaping (Item) -> Leading,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.items = items
        self._searchText = searchText
        self.emptyTitle = emptyTitle
        self.emptyIcon = emptyIcon
        self.emptyDescription = emptyDescription
        self.onDelete = onDelete
        self.onMove = onMove
        self.scrollToID = scrollToID
        self.leadingActions = leadingActions
        self.row = row
        self._revealed = State(initialValue: scrollToID == nil)
    }

    private var reorderEnabled: Bool {
        onMove != nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Mac Catalyst renders `List` rows with AppKit's tight default metrics, which crams the
    /// config lists (Articles/Feeds/Tags) into a cramped, hard-to-scan wall of text. Give each
    /// row extra vertical breathing room on the Mac; iOS keeps SwiftUI's native row insets (nil).
    private var rowInsets: EdgeInsets? {
        #if targetEnvironment(macCatalyst)
        EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        #else
        nil
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    row(item)
                        .listRowInsets(rowInsets)
                        .swipeActions(edge: .leading) {
                            leadingActions(item)
                        }
                        // Only the row being scrolled to reports its position, and only while the
                        // reveal is still pending — every other row pays nothing.
                        .modifier(TargetRowPositionProbe(
                            isTarget: !revealed && scrollToID != nil && item.id == scrollToID,
                            onPosition: targetRowDidReport
                        ))
                }
                .onDelete(perform: onDelete)
                .onMove(perform: reorderEnabled ? onMove : nil)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
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
            // Rows stay invisible (but laid out, so the scroll below can resolve them) until the
            // target has been scrolled to — see `scrollToTargetIfNeeded`.
            .opacity(revealed ? 1 : 0)
            // Land on the target row once. A synchronous scroll on first appear is dropped because
            // the List lays out its rows asynchronously, and the target may not even exist yet when
            // the items are still streaming in — so retry across a few frames, and also re-arm when
            // the id transitions from nil to a value as rows arrive.
            .onAppear { scrollToTargetIfNeeded(proxy) }
            .onChange(of: scrollToID) { _, _ in scrollToTargetIfNeeded(proxy) }
        }
    }

    /// Scrolls the target row into view before the user ever sees the list.
    ///
    /// `ScrollViewProxy` can only scroll a row the List has already laid out, so this cannot happen
    /// before the first layout pass — which is exactly why it used to read as the list opening at the
    /// top and then jumping down to the current article. (Seeding a `ScrollPosition` in `init`
    /// instead, the declarative equivalent, was tried and verified to do nothing at all for a
    /// `List`.) So the scroll still runs after layout, but the rows are held at `opacity(0)` until
    /// it's done: the sheet slides in blank for a few frames and its content appears already parked
    /// on the right row, with no visible travel.
    ///
    /// The scroll is issued with animations explicitly disabled, so it can't inherit an in-flight
    /// presentation animation and play out as a visible glide.
    ///
    /// Retried across a few frames because an attempt made before the List has laid its rows out is
    /// silently dropped. The reveal is not tied to those attempts, though — it happens when the
    /// target row actually reports itself on screen (`targetRowDidReport`); the last attempt only
    /// force-reveals as a backstop, so a target that can never report (filtered out from under us,
    /// say) cannot leave the list invisible.
    private func scrollToTargetIfNeeded(_ proxy: ScrollViewProxy) {
        guard let scrollToID else { revealed = true; return }
        guard !didScrollToTarget else { return }
        didScrollToTarget = true
        Task { @MainActor in
            for delayMS in [0, 60, 250] {
                try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                if revealed { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(scrollToID, anchor: .center) }
                // Give the scroll one frame to take effect, so the position being judged below is
                // the post-scroll one.
                try? await Task.sleep(nanoseconds: 16_000_000)
                scrollHasSettled = true
                if delayMS == 250 { revealed = true } else { revealIfTargetIsOnScreen() }
            }
        }
    }

    private func targetRowDidReport(_ frame: CGRect) {
        targetRowFrame = frame
        revealIfTargetIsOnScreen()
    }

    /// The reveal condition: the target row sits fully within the list's own bounds, i.e. the scroll
    /// really has put it on screen. Positions reported before the scroll settled don't count — see
    /// `scrollHasSettled`.
    private func revealIfTargetIsOnScreen() {
        guard !revealed, scrollHasSettled, let frame = targetRowFrame else { return }
        revealed = ManagedListReveal.isRowFullyVisible(row: frame, inList: listFrame)
    }
}

/// The geometric half of `ManagedList`'s reveal rule, split out from the view so it can be tested
/// directly — the timing half (when the scroll has settled) can only be verified by driving the app.
enum ManagedListReveal {
    /// Whether `row` is fully inside `list` vertically. A zero-height `list` means it hasn't been
    /// measured yet, which is never "visible".
    static func isRowFullyVisible(row: CGRect, inList list: CGRect) -> Bool {
        guard list.height > 0, row.height > 0 else { return false }
        return row.minY >= list.minY && row.maxY <= list.maxY
    }
}

/// Reports the row's frame while `isTarget` is set, so `ManagedList` can reveal its rows the moment
/// the row it scrolled to is genuinely on screen. Written as a `ViewModifier` taking `isTarget` (not
/// applied conditionally at the call site) so a row's identity and its `List` metadata don't change
/// when the flag flips.
private struct TargetRowPositionProbe: ViewModifier {
    let isTarget: Bool
    let onPosition: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background {
            if isTarget {
                // A `GeometryReader`, not `onGeometryChange`, because the row may well be realized
                // already sitting in its final place: that produces no *change* to report, and the
                // reveal would be left waiting on the backstop. `onAppear` covers that first
                // position, `onChange` the ones the scroll produces.
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    Color.clear
                        .onAppear { onPosition(frame) }
                        .onChange(of: frame) { _, new in onPosition(new) }
                }
            }
        }
    }
}

extension ManagedList where Leading == EmptyView {
    init(
        items: [Item],
        searchText: Binding<String>,
        emptyTitle: LocalizedStringKey,
        emptyIcon: String,
        emptyDescription: LocalizedStringKey,
        onDelete: ((IndexSet) -> Void)? = nil,
        onMove: ((IndexSet, Int) -> Void)? = nil,
        scrollToID: Item.ID? = nil,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.init(items: items, searchText: searchText, emptyTitle: emptyTitle, emptyIcon: emptyIcon,
                  emptyDescription: emptyDescription, onDelete: onDelete, onMove: onMove,
                  scrollToID: scrollToID, leadingActions: { _ in EmptyView() }, row: row)
    }
}
