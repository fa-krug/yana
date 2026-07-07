# App Store Screenshot Automation — Design

**Date:** 2026-07-06
**Status:** Implemented

> **Implementation deltas** (this doc is the original design; the following changed during
> build): (1) **iPhone-only** — iPad was dropped and the app target set to
> `TARGETED_DEVICE_FAMILY = 1`, so output is 4 framed PNGs on the 6.9″ iPhone, not 8 across
> two devices. (2) Lead images are **generated at runtime** by `ScreenshotImageFactory`
> (Core Graphics gradients), not bundled in the asset catalog as the "Content Fixture"
> section below describes — this keeps the fixture fully offline with no committed image
> binaries. (3) The frameit caption font (`OpenSans-Bold.ttf`, SIL OFL) is bundled under
> `fastlane/screenshots/`, and the framing background is a solid image sized to 1320×2868.
> Sections below reflect the original plan; see `CLAUDE.md` / `README.md` for the shipped
> behavior.

## Goal

Autogenerate App-Store-compatible, **framed and captioned** marketing screenshots for the
Yana iOS release. Fully reproducible, offline (no network), regenerated with a single
fastlane lane.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Deliverable | Framed + captioned marketing images |
| Toolchain | fastlane `snapshot` (capture) + `frameit` (frame/caption) |
| Devices | 6.9″ iPhone (`iPhone 17 Pro Max`) — **iPhone-only** (iPad dropped 2026-07-06; app is now `TARGETED_DEVICE_FAMILY = 1`) |
| Languages | English only (`en-US`) |
| Shots (ordered) | 1) Reader 2) Timeline/list 3) Search 4) Feeds & tags |

Total output: **4 shots × 1 device = 4 framed PNGs**, plus the raw (unframed) captures.

## Content Fixture — `ScreenshotSeed`

A new DEBUG-only seeder, **separate from `DebugSeed`**, gated behind the launch argument
`-UITEST_SCREENSHOTS` (not the `YANA_SEED_ARTICLES` env var) so it never touches the
cold-start performance-measurement path.

On launch, when the argument is present and the store is empty, it inserts:

- **~15 curated articles** with realistic titles, feed names, authors, and dates. Feed
  names deliberately span aggregator types to show variety: e.g. a news site (Heise /
  Tagesschau), a YouTube channel, a subreddit, a podcast. Dates spread across recent days.
- **Bundled local lead images** — a small set of royalty-free/original images added to the
  app bundle (asset catalog) and written into `ImageStore` under `yana-img://` refs, so the
  timeline and reader render populated with **zero network calls**.
- **Several colored tags** applied to feeds/articles (including the built-in Starred on one),
  so the tag filter and Feeds screen look real.
- An **AI `summary`** field populated on the hero article, so the reader's summary block
  renders between the lead image and body.
- A **parked timeline anchor** on the hero article (`AppSettings.timelineAnchorIdentifier`)
  so the reader opens directly on it — shot #1 needs no navigation.

Images: bundle 4–6 static images in the asset catalog under a `ScreenshotAssets` namespace.
`ScreenshotSeed` copies their PNG data into `ImageStore` and references them from the block
bodies / lead-image field. No `<img>` URLs, no fetches.

## Capture Flow — `ScreenshotUITests`

New UITest target file `YanaUITests/ScreenshotUITests.swift`, one ordered test method.
Uses fastlane snapshot's generated `SnapshotHelper.swift` (`setupSnapshot(app)` +
`snapshot(name)`).

Launch: `app.launchArguments += ["-UITEST_SCREENSHOTS"]`, then `setupSnapshot(app)`,
then `app.launch()`.

Steps (each waits on a stable accessibility identifier before snapping):

1. App opens on hero article in the reader → `snapshot("01_Reader")`
2. Tap the article-list toolbar button → article-list sheet → `snapshot("02_Timeline")`
3. Focus the list's search field, type a query that matches several items →
   `snapshot("03_Search")`
4. Dismiss, open Settings → navigate to the Feeds & tags section → `snapshot("04_Feeds")`

**Accessibility identifiers to add** (implementation detail, finalized in the plan): the
reader toolbar buttons for article-list and settings, and the Feeds section entry, so the
test can navigate deterministically. Existing `emptyArticlesTitle` is the pattern to follow.

## Framing — `frameit`

- `fastlane/screenshots/Framefile.json` — fonts, caption text color, background color,
  padding, and per-device frame selection.
- Per-shot English captions in `fastlane/screenshots/en-US/title.strings` keyed by the
  snapshot file names above.
- Device frames pulled from fastlane's community frames (`frameit download_frames` /
  the `frameit-frames` repo).

Draft caption copy (editable):

1. `01_Reader` — "Read it your way — clean, native, no browser"
2. `02_Timeline` — "Everything you follow, in one timeline"
3. `03_Search` — "Find any article instantly"
4. `04_Feeds` — "RSS, YouTube, Reddit & podcasts — one app, fully on-device"

**Risk — device frames:** the community frames repo may lack the newest device frames. We
use the closest available 6.9″ iPhone frame and 12.9/13″ iPad frame. The underlying captures
are still valid App Store resolutions regardless of frame:
- 6.9″ iPhone: 1320 × 2868
- 13″ iPad: 2048 × 2732

If a needed frame is missing, the fallback is to ship the **unframed** captures for that
device (still store-valid) and note it — framing is cosmetic, not a validity requirement.

## fastlane Wiring

- `Gemfile` + `Gemfile.lock` pinning `fastlane`.
- `fastlane/Snapfile`:
  - `devices(["iPhone 16 Pro Max", "iPad Pro 13-inch (M4)"])` (exact sim names resolved
    against installed simulators during implementation)
  - `languages(["en-US"])`
  - `scheme("Yana")`
  - `output_directory("./fastlane/screenshots")`
  - `clear_previous_screenshots(true)`
  - `test_target_name` / only run `ScreenshotUITests`
- `fastlane/Fastfile` lane `screenshots`:
  ```ruby
  lane :screenshots do
    capture_screenshots
    frame_screenshots
  end
  ```
- Output: `fastlane/screenshots/en-US/*.png` (raw) and `*_framed.png`.

## Documentation

- Short "Generating App Store screenshots" section in a docs file / README.
- A note in `CLAUDE.md` on the `fastlane screenshots` command and the `-UITEST_SCREENSHOTS`
  fixture, so regeneration is discoverable.

## Verification (acceptance)

The pipeline is the deliverable; acceptance = a clean end-to-end run producing:
- 4 framed PNGs (4 shots × 1 device, iPhone-only) at 1320×2868 (the framing background is
  sized to that resolution so framed output stays App-Store-valid).
- Each UITest step asserts its screen rendered non-empty (identifier exists) before
  snapping, so an empty/blank screenshot fails the run rather than shipping silently.
- `xcodegen generate` still succeeds and the normal build/test remain green
  (`ScreenshotSeed` and the new UITest are DEBUG-only and gated by the launch argument).

## Out of Scope (YAGNI)

- German screenshots (English-only per decision; de listing reuses en).
- 6.5″ iPhone and other legacy sizes.
- CI integration / automated upload to App Store Connect (manual upload for this release).
- A privacy/settings-specific shot (search covers the differentiator slot).
