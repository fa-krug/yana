# macOS Article Toolbar: Segmented Pill + Smooth Progress Spinner

**Date:** 2026-07-25
**Scope:** `Yana/Reader/Mac/MacRootView.swift` (the Mac Catalyst window's detail-pane toolbar)

> **Superseded 2026-07-28 — the hand-rolled pill is gone.** The joined group is now a SwiftUI
> `ControlGroup` hosted **directly by a `ToolbarItem`**, which renders its segments correctly; the
> empty-pill bug this spec worked around applies to a `ControlGroup` nested inside a
> `ToolbarItemGroup`, which is how it was written when the bug was hit (commit `0cf55dc`).
> `ToolbarItemGroup` alone does *not* join its members on Catalyst — verified from captured window
> screenshots: they render as separate round buttons. The `More` menu stays a **separate item**
> beside the group (as this spec had it) with its pull-down chevron suppressed via
> `.menuIndicator(.hidden)`, every other Mac toolbar (Feeds, Diagnostics) uses
> the same construction, and lone toolbar buttons get horizontal label padding
> (`MacToolbarMetrics.iconPadding`) so their background is a circle and not an upright oval. The
> spinner design below (cross-fade in place, constant item set, ~0.5 s minimum visibility) is
> unchanged and still current.

## Problem

The Mac window's article toolbar currently renders the four primary actions
(`Update all`, `Star`, `Read Aloud`, `Open Page`) as **four separate plain buttons** followed by
a `More` menu. It reads as a loose row rather than a grouped control. Progress ("an update or
summarize is running") is shown by a `.symbolEffect(.rotate)` on the `Update all` arrow, which
**flickers**: the effect restarts whenever the Catalyst toolbar re-validates (the same
re-validation event documented in the `catalyst-controlgroup-toolbar-empty` note — e.g. when an
iCloud sync repopulates the `NavigationSplitView` detail pane and the UIKit reader VC re-enters
the responder chain).

The earlier attempt to group these with a SwiftUI `ControlGroup` was abandoned because a
`ControlGroup` nested in a Catalyst window toolbar renders its content **empty** (a blank pill)
after that re-validation.

## Goals

1. Present the primary actions as **one visually-joined segmented pill**, with the `More` menu as
   a **separate button** beside it.
2. Replace the rotating-arrow symbol effect with a **standard indeterminate circular progress
   spinner** in the toolbar.
3. The spinner animates in and out **smoothly, with no flickering**.
4. The spinner is the **same size as the toolbar buttons** (not the default small control size).

## Design

### Segmented pill (hand-rolled, not `ControlGroup`)

`ControlGroup` is unusable here (empty-pill bug), so build the pill by hand:

- A single `ToolbarItem(placement: .primaryAction)` whose content is an `HStack(spacing: 0)` of the
  four action buttons — order: **Star · Read Aloud · Open Page · Update all** — with a thin
  `Divider` between each segment.
- The buttons use a borderless/plain button style so they read as segments of one control, and the
  whole `HStack` sits on a single rounded/capsule bordered background (glass), giving the joined
  look. Per-button `.help(...)` tooltips and `.disabled(model.selectedSummary == nil)` state on the
  per-article actions are preserved. `Update all` (global) is never disabled.
- Reliability: this is just `Button`s inside an `HStack` — both render fine in this toolbar (the
  bug note's differential tell is that a sibling `Menu` renders while only `ControlGroup` fails), so
  the hand-rolled pill dodges the `ControlGroup` teardown entirely.

The existing `More` `Menu` (Settings / Summarize / Reload / Copy link) stays as its **own**
`ToolbarItem`, adjacent to the pill.

### Indeterminate progress spinner

- Remove the `.symbolEffect(.rotate, …)` from `Update all`; it becomes a static `arrow.clockwise`.
- Add a dedicated `ProgressView().progressViewStyle(.circular)` as its **own** toolbar item,
  leading the pill. It is sized to **match the toolbar buttons** (framed to the button control
  size rather than left at the default `.small` circular size).

### No-flicker principle

- **The toolbar item set never changes.** The spinner item is *always present* in the toolbar; it
  is shown/hidden only via `.opacity` driven by the existing `showSpinner` `@State`, animated with
  `.animation(.easeInOut)`. Adding/removing a toolbar item is what triggers Catalyst's
  re-validation teardown, so we never do that.
- The busy signal is already stable: `triggerRefresh`/`summarize` route through
  `UpdateActivity.restart` → a single `run`, so `inFlight` stays at `1` for a whole `updateAll`
  (no per-feed blink). `showSpinner` continues to be re-driven inside `withAnimation` from the
  existing `.onChange(of: UpdateActivity.shared.isUpdating || model.isSummarizing)`.
- **Minimum-visible duration (~0.5s):** a sub-second update would otherwise flash the spinner on
  for a few frames and off again — itself a flicker. When the busy signal drops, keep the spinner
  visible until at least ~0.5s has elapsed since it appeared, then fade it out. Implemented in the
  view layer (a short awaited delay before clearing `showSpinner`), keeping the model unchanged.

## Non-goals

- No determinate/percentage progress (the aggregation `UpdateProgress` counts are not surfaced
  here).
- No change to the iOS/iPad reader toolbar, the sidebar, or any non-Mac path.
- No change to `UpdateActivity`, `TimelineModel`, or `AggregationService` semantics.

## Testing

This is a Catalyst-only, visual toolbar change with no pure business logic to unit-test in
isolation; verification is by building the Mac Catalyst target and confirming: (a) the pill renders
as one joined control with a separate More button, (b) the spinner appears/disappears smoothly
without flicker during an `Update all`, and (c) the spinner matches button size. Any extracted pure
helper (e.g. a min-visible-duration timing helper, if factored out) gets a Swift Testing unit test.
