# Pin the Currently-Displayed Article's Sort Position

**Date:** 2026-08-12
**Status:** Draft, pending user review
**Related:** [2026-08-06-read-state-sort-design.md](2026-08-06-read-state-sort-design.md)
(that spec introduced `readRank`-first sorting and mark-read-on-display; this spec fixes the visible
reshuffle that design causes, and extends coverage to the Mac sidebar and the article list screen)

## Problem

The timeline sorts by `(readRank, date)`: unread articles first, then read articles, oldest-first
within each block. An article is marked read the instant it becomes the currently-displayed one
(iOS pager swipe completion, iOS list-open, Mac sidebar selection — see the related spec). That
`read` flip immediately changes the article's sort key, so it visibly jumps out of the unread block
into the read block while the user is still looking at it or navigating around it — "reshuffling
under the user's finger."

iOS's reader (`ReaderHostView`) already has a mitigation, `TimelineDisplayOrder.merge` (`Yana/Utilities/TimelineFiltering.swift`), which tries to preserve whatever position an article held in the
*previous* render of `filteredArticles` rather than adopting the freshly-sorted canonical order. In
practice this is unreliable: because it works by tracking prior array positions rather than computing
a correct position, it drifts as the array changes shape (filter toggles, sync-driven insertions/removals, list-open), and the user still observes the reshuffle in the iOS reader pager. Mac's
`TimelineModel.recomputeFilter()` never adopted any preservation mechanism at all, so the Mac sidebar
reorders on every selection change. The article-list/search screen (`ArticleListView`) has no
preservation either.

## Goal

Replace history-dependent order preservation with a small, stateless, always-correct transform: the
currently-displayed article's position in the sorted list is pinned as if it were still unread, for
as long as it remains the currently-displayed article. The read flag itself is unaffected — it's
still written immediately, so unread counts/badges and the "last article in the timeline" case both
stay correct (per the earlier decision that we don't want an eternally-unread article just because
the user quit without navigating again).

This applies uniformly to all three places that render a `(readRank, date)`-sorted view of the
timeline:
- iOS reader pager (`ReaderHostView.filteredArticles`)
- Mac sidebar/pager (`TimelineModel.filteredArticles`)
- Article list / search screen (`ArticleListView.results`), browsing mode only — its search mode
  sorts by `date` alone (no read/unread blocks to jump between), so pinning is skipped there.

## Decisions

| Decision | Choice |
| --- | --- |
| Mechanism | A single pure function, computed fresh from the canonical `(readRank, date)`-sorted input every time — not a diff against a remembered previous array. This is what makes it correct regardless of history (filter changes, sync insertions, list reopen all "just work"). |
| Pin target | The identifier of the article currently open/displayed in that view's own context: `AppSettings.timelineAnchorIdentifier` for `ReaderHostView` and `TimelineModel` (already updated synchronously on every navigation, right before `markRead` fires); the existing `currentArticleID` parameter for `ArticleListView` (already threaded in, previously used only for row highlighting/scroll). |
| What "pinning" does | If the pinned article is present in the input and `isRead == true`, remove it and reinsert it at the date-sorted position it would occupy among the *unread* block (i.e., treat it as unread for sort purposes only). If it's unread already, or not found, the input is returned unchanged. |
| `read`/`readRank` write timing | Unchanged — still set immediately at all three existing call sites (`ArticleWrites.markRead`), per the related spec. Nothing about *when* the flag flips changes; only display order is affected. |
| Old mechanism | `TimelineDisplayOrder.merge` and the `preservingOrder` parameter split in `ReaderHostView.recomputeFilter` are deleted outright, not kept as a fallback. |
| Mac parity | `TimelineModel.recomputeFilter()` gains the same pinning call it never had — this is a real behavior fix, not just refactoring. |
| Article list scope | Only the plain-browsing `results` computed property is pinned; the search-mode branch (`searchResults`, sorted by `date` only) is left as-is. |
| Where the new code lives | `Yana/Utilities/TimelineFiltering.swift`, alongside the existing `TagFilter`/`FeedFilter`/`StarredFilter`/`TimelineIdentifiable` — same file, same conventions. |

## Architecture

### New utility: `TimelinePinning`

Replaces `TimelineDisplayOrder` in `Yana/Utilities/TimelineFiltering.swift`:

```swift
enum TimelinePinning {
    /// Reinserts `pinnedIdentifier`'s row at the position it would occupy if it were still unread,
    /// when it's actually read. Leaves `articles` unchanged otherwise (including when the pinned
    /// article isn't present, or is already unread). `articles` must already be in canonical
    /// `(isRead, date)` order.
    static func apply<T: TimelineIdentifiable>(to articles: [T], pinning pinnedIdentifier: String?) -> [T] {
        guard let pinnedIdentifier,
              let pinnedIndex = articles.firstIndex(where: { $0.identifier == pinnedIdentifier }),
              articles[pinnedIndex].isRead
        else { return articles }

        var result = articles
        let pinned = result.remove(at: pinnedIndex)
        let unreadEnd = result.firstIndex(where: { $0.isRead }) ?? result.count
        let insertionIndex = result[0..<unreadEnd].firstIndex { $0.date > pinned.date } ?? unreadEnd
        result.insert(pinned, at: insertionIndex)
        return result
    }
}
```

`TimelineIdentifiable` (already declared in this file for `merge`) needs two more requirements added
— `isRead: Bool` and `date: Date` — alongside its existing `identifier: String`. `ArticleSummary`
already exposes all three, so no model changes are needed there.

### Call site changes

- **`ReaderHostView.recomputeFilter()`** (`Yana/Reader/ReaderHostView.swift`): drop the
  `preservingOrder` parameter entirely; always compute canonical order via the existing
  `TagFilter`/`FeedFilter`/`StarredFilter` chain, then `TimelinePinning.apply(to: canonical, pinning: settings.timelineAnchorIdentifier)`. All call sites of `recomputeFilter` (the filter-toggle
  `.onChange` handlers, `openArticle`, the `store.summaries` `.onChange`) collapse to the same call —
  there's no longer a "fresh vs. preserved" distinction to choose between.
- **`TimelineModel.recomputeFilter()`** (`Yana/Reader/Mac/TimelineModel.swift`): same pattern, newly
  added — this view had no order-correction step before.
- **`ArticleListView.results`** (`Yana/Views/Config/ArticleListView.swift`): wrap the existing
  browsing-mode chain (`base = store.summaries` path only, not `searchResults`) with
  `TimelinePinning.apply(to:pinning: currentArticleID)`.

### What's deleted

- `TimelineDisplayOrder` (the merge-based type) and its dedicated tests.
- The `preservingOrder: Bool` parameter and its two call-site variants in `ReaderHostView`.

## Testing

- `TimelinePinning.apply`: pinned+read article is reinserted at the correct date-sorted position
  within the unread block (including edge cases: pinned article is the oldest/newest unread, or the
  unread block is empty); pinned-but-still-unread article is a no-op; unknown/`nil` pin identifier is
  a no-op; non-pinned articles' relative order is untouched.
- `ReaderHostView`-level (or as close as the existing test harness allows): marking the current
  article read via the pager does not change its position in `filteredArticles` until the anchor
  moves to a different article.
- New `TimelineModelTests` case: selecting a new row and confirming the just-left row's position is
  unaffected while the newly-selected (now pinned) row does not jump into the read block — mirrors
  the existing `settingSelectionMarksTheNewArticleRead`/`moveSelectionMarksTheNewArticleRead` tests,
  extended to also assert on ordering, not just the `read` flag.
- `ArticleListView`: a test (if this view has any existing coverage — checked during planning)
  confirming a read, pinned `currentArticleID` row stays in its unread-block position, and that
  search-mode results are unaffected by pinning.

## Documentation impact

`CLAUDE.md`'s **Key patterns → Read state drives the primary sort** section already documents the
`readRank`/mark-on-display design from the related spec; it should gain a note that the currently-
displayed article's position is pinned as unread until the anchor moves on, so the sort description
stays accurate. The **Views** section's mentions of `ArticleListView`/`ReaderHostView`/`TimelineModel`
don't currently name `TimelineDisplayOrder` explicitly, so no correction is needed there beyond
whatever incidental wording review turns up while editing.
