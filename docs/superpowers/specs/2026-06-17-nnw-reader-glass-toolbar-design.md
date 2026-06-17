# NNW-style reader toolbar: glass-over-content (no black top band)

**Date:** 2026-06-17
**Status:** Approved

## Goal

Make the reader's top toolbar look like NetNewsWire's: floating liquid-glass
controls that refract the live article content behind them, instead of glass
pills sitting over a solid black band.

## Problem

The reader currently shows a black band behind the top toolbar pills. Traced to:

- The pager's hosting views set `backgroundColor = .systemBackground` (black in
  dark mode): `ArticlePagerView.swift:63` (`ArticlePagerController.view`) and
  `:241` (`ArticlePage.view`).
- The web view is transparent (`ArticleWebView.swift:74-76`), so the black shows
  through wherever content is not drawn.
- Article content is inset from the top by `readerContentInset.top =
  safeAreaInsets.top` (`ArticleContentView.swift:37-45`).
- `safeAreaInsets` is captured by a `GeometryReader` placed **inside** the
  `NavigationStack` (`ArticleReaderView.swift:41`). At that position the safe
  area top includes the transparent navigation bar's reserved height
  (≈ status bar + nav bar ≈ 103pt), not just the status bar (≈ 59pt).

Net effect: content starts ~103pt down; the nav-bar band (≈59–103pt) exposes the
black `systemBackground` behind the transparent glass pills.

NetNewsWire instead lets content flow **under** the floating buttons, so the
glass refracts the article; only the status-bar zone stays dark.

## Fix

Inset the article content by the **device/status-bar** top inset (≈59pt) instead
of the nav-bar-inclusive top. Content then flows under the transparent glass
toolbar, the pills refract real content (NNW look), and the black band collapses
to just the status-bar zone (dark in NNW too).

Implementation: capture the safe area with a `GeometryReader` placed **outside**
the `NavigationStack` (where the nav bar has not reserved space yet) and forward
that device inset to `ArticlePagerView`. No UIKit window lookups.

- `ArticleReaderView.body`: wrap the `NavigationStack` in a `GeometryReader`;
  use its `safeAreaInsets` (device insets) as the value forwarded to the pager.
  Remove the inner `GeometryReader` that captured nav-bar-inclusive insets.
- Everything downstream (`ArticlePagerView` → `ArticleContentView` →
  `ArticleWebView`) is unchanged; it already consumes the forwarded insets.

## Bottom action bar: NNW-scale icons

The floating bottom glass bar (open-in-browser, share) rendered its icons at the
default (~body) size, much smaller than NetNewsWire's. Enlarge them:

- `ArticleContentView.bottomBar`: apply `.font(.title2)` to the icon buttons.
- Bump `actionBarHeight` 60 → 76 so the article's last line still clears the
  taller bar (it feeds the bottom content inset).

This is a custom (non-system) bar, so it is free to size icons unlike the top
system toolbar.

## Out of scope / unchanged

- System `.toolbar` stays — star + gear remain **bundled** in one glass capsule
  (iOS 26 auto-groups adjacent trailing items); filter stays leading.
- `.toolbarBackground(.hidden)`, all button functions, the bottom glass bar,
  pull-to-refresh, sheets, and accessibility labels are untouched.
- Icon sizes stay system-sized (consequence of keeping the system toolbar).

## Accepted trade-off

With content flowing under, the article title's first line can slightly underlap
the floating pills on initial load (faded under glass) — this is exactly NNW's
behavior. Adding a larger top inset to clear the pills would reintroduce a
smaller black band, so we keep the overlap.

## Verification

- Build: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Visual: launch the reader in dark mode; confirm no black band behind the top
  pills — article text is visible/refracted behind the glass; status-bar zone
  stays dark. Scroll and confirm text passes under the pills.
- Confirm bottom glass bar and content bottom inset are unchanged.
