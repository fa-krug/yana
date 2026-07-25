# macOS App Store Screenshots — Design

**Date:** 2026-07-25
**Status:** Approved, ready for implementation planning

## Goal

Produce Mac App Store screenshots for the Mac Catalyst build, reproducibly and offline, in
English and German — mirroring the intent of the existing iPhone `fastlane screenshots` flow
without reusing its machinery.

## Why the iOS flow cannot be reused

Two hard blockers:

1. **`capture_screenshots` (fastlane snapshot) is iOS-simulator-only.** It drives
   `platform=iOS Simulator` destinations; it cannot target `platform=macOS,variant=Mac Catalyst`.
2. **`frame_screenshots` (frameit) has no Mac device frames.** The iPhone set's device bezel,
   indigo→violet gradient background and two-tone captions have no Mac equivalent.

A third, softer blocker: the Mac UI carries essentially **no accessibility identifiers**
(`MacRootView.swift:317` has a single `accessibilityLabel` on the star icon), so a Mac UI test
has nothing locale-independent to navigate by.

Consequently the Mac path gets its own test, its own lane, and its own output directory. The
one thing it *does* reuse is the offline content fixture (`ScreenshotSeed`), which needs no
changes — it has no platform conditionals and its UIKit-based image factories behave identically
on Catalyst.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Shot count | 4: `01_Reader`, `02_Search`, `03_Feeds`, `04_AI` | Ports the iOS story minus `02_Timeline`, which the Mac sidebar already shows in shot 1 |
| Visual treatment | Plain captures, no gradient, no captions | Dominant Mac App Store convention; no compositor for text, no extra caption files to translate |
| Settings shots | Settings window composited over the main window | Matches the real floating-window look; a bare 720×620 window or a padded one looks unfinished |
| Capture mechanism | `XCTAttachment` + `xcresulttool export attachments` | Sandbox-safe; the Catalyst test runner cannot write outside its container. Failed runs leave inspectable artifacts |
| Output size | 2880×1800 px | Largest allowed Mac App Store size (16:10); 1440×900pt at 2x |

## Architecture

Five units, each independently understandable:

```
project.yml                              → lets the test bundles build for Catalyst
Yana/Utilities/MacScreenshotWindow.swift → forces deterministic window geometry (DEBUG, Catalyst)
Yana/Reader/Mac/* (identifiers only)     → gives the test locale-independent navigation targets
YanaUITests/MacScreenshotUITests.swift   → navigates and attaches window captures
fastlane/mac_composite.swift             → composites overlay onto base, emits exact 2880×1800
fastlane/Fastfile (lane :screenshots_mac)→ orchestrates: test → export → composite → place
```

### 1. Build configuration

`YanaUITests` and `YanaTests` both need Catalyst support in `project.yml`, because `xcodebuild`
builds every test target in the `Yana` scheme even when `-only-testing` narrows execution:

```yaml
SUPPORTS_MACCATALYST: true
TARGETED_DEVICE_FAMILY: "1,2,6"
DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: false
```

### 2. Deterministic window geometry

New `Yana/Utilities/MacScreenshotWindow.swift`, wrapped in `#if DEBUG` and
`#if targetEnvironment(macCatalyst)`. Activated by the `-UITEST_MAC_SCREENSHOTS` launch argument.

Responsibilities:

- Pin the **main** window to exactly 1440×900pt using
  `UIWindowScene.requestGeometryUpdate(.Mac(...))`, temporarily clamping the scene's
  `sizeRestrictions` (`minimumSize == maximumSize == target`) to force the exact size, then
  relaxing them. `MacRootView`'s sidebar minimum (300pt) is well within 1440pt, so no conflict.
- Suppress the Mac launch refresh (`YanaApp.swift:139-143`, a 3-second delayed `updateAll()`), so
  no toolbar progress spinner or error toast can leak into a capture.

The Settings window is left at its natural 720×620 — it is the overlay, not the canvas.

### 3. Accessibility identifiers

Added purely to make navigation deterministic and locale-independent (EN/DE labels differ):

- `MacRootView` — `mac.window.root`, `mac.sidebar.list`, `app.searchFields`
- `MacSettingsWindow` — `mac.settings.window`, and `mac.settings.pane.<SettingsPane.rawValue>`
  on each of the seven pane rows

This is the minimum needed; no other Mac view is touched.

### 4. Capture flow — `YanaUITests/MacScreenshotUITests.swift`

Two test methods, `testCaptureScreenshotsEnglish` and `testCaptureScreenshotsGerman`, both
delegating to a shared `capture(locale:)`. Splitting by method (rather than plumbing an
environment variable through `TEST_RUNNER_*`) keeps the lane a plain `-only-testing:` selection.

Launch arguments per pass:

- `-UITEST_SCREENSHOTS` — seed the offline fixture, skip onboarding, preselect an AI provider
- `-UITEST_RESET_LIBRARY` — wipe feeds/articles/tags first
- `-UITEST_MAC_SCREENSHOTS` — force window geometry, suppress launch refresh
- `-AppleLanguages (en|de)`, `-AppleLocale (en_US|de_DE)` — force locale

Per-locale isolation replaces the iOS lane's `erase_simulator`. There is no simulator to erase,
but reset-then-seed is equivalent: `YanaApp.swift:45-48` runs `UITestReset.resetIfRequested()`
before `ScreenshotSeed.seedIfRequested()`, so the seed's "bail if any `Feed` exists" guard passes
because reset has just emptied the store. Reset also clears `timelineAnchorIdentifier`, and the
seed re-parks it on the hero article.

| Shot | Action | Attachment |
|---|---|---|
| `01_Reader` | Wait for `mac.sidebar.list`; settle 2s for async feed logos (`FeedLogoView` has no cache) | `01_Reader.png` |
| `02_Search` | Type "battery" into `app.searchFields`; wait for result rows; then clear | `02_Search.png` |
| `03_Feeds` | ⌘, → wait for `mac.settings.window` → click `mac.settings.pane.feeds` | `03_Feeds.overlay.png` |
| `04_AI` | Click `mac.settings.pane.ai` | `04_AI.overlay.png` |

**Composite base:** the `01_Reader` capture is reused as the base for both Settings composites.
Capturing the main window *while* the Settings window floats over it risks the occluding window
bleeding into the result, so the base is taken before Settings is ever opened.

All attachments set `lifetime = .keepAlways` so they survive into the result bundle.

Navigation fallback: if ⌘, does not open Settings, fall back to the toolbar overflow menu
(`MacRootView`'s ellipsis → Settings).

### 5. Compositor — `fastlane/mac_composite.swift`

Invoked as `xcrun swift fastlane/mac_composite.swift <base> <overlay> <out>`. CoreGraphics only —
no Homebrew dependency (`sips` cannot composite; ImageMagick and Pillow are external).

Steps: draw the base; draw a soft drop shadow; draw the overlay centered; write PNG at exactly
2880×1800, scaling the base first if the host display was not 2x.

### 6. Lane — `platform :mac`, `lane :screenshots_mac`

Per locale:

1. `xcodebuild test -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst'
   -only-testing:YanaUITests/MacScreenshotUITests/testCaptureScreenshots<Locale>
   -resultBundlePath <tmp>.xcresult`
2. `xcrun xcresulttool export attachments --path <tmp>.xcresult --output-path <tmp>/att`
3. Read `<tmp>/att/manifest.json`, map each attachment's suggested name to its target filename,
   copy into `fastlane/screenshots_mac/<locale>/`
4. Composite `03_Feeds` and `04_AI` from `01_Reader.png` + their `*.overlay.png`
5. Delete the `*.overlay.png` intermediates

The lane inherits the existing `ENV["LANG"] ||= "en_US.UTF-8"` guard at the top of the Fastfile.

### 7. Output layout

```
fastlane/screenshots_mac/en-US/{01_Reader,02_Search,03_Feeds,04_AI}.png
fastlane/screenshots_mac/de-DE/{01_Reader,02_Search,03_Feeds,04_AI}.png
```

Committed, matching the iOS set's convention. Deliberately **outside** `fastlane/screenshots/`
so the iOS lane's `frame_screenshots` (which scans that directory) never picks up Mac captures.
`.gitignore` gains `*.xcresult`.

## Error handling

- **Test navigation failures** — `continueAfterFailure = false`, with an explicit
  `XCTAssertTrue(...waitForExistence...)` and a descriptive message at each navigation step, in
  the style of the existing `ScreenshotUITests`.
- **Missing attachments** — the lane fails loudly if `manifest.json` lacks an expected shot,
  rather than silently emitting an incomplete set.
- **Wrong output size** — the compositor asserts the final canvas is exactly 2880×1800.
- **Non-Retina host** — the compositor scales the base rather than emitting an undersized image.

## Testing

- The screenshot test is itself the integration test for the flow.
- One unit test for the pure geometry helper in `MacScreenshotWindow` (target-size parsing /
  clamping), added to `YanaTests`.
- No new user-facing strings, so `Localizable.xcstrings` is untouched — every addition here is
  DEBUG- or test-only.

## Risks and caveats

- Exact 2880×1800 assumes a Retina (2x) display; the compositor normalizes otherwise, but a 1x
  host yields an upscaled image.
- A Catalyst app instance already running can interfere with window reuse; the lane should
  ensure a fresh launch.
- `xcresulttool export attachments` is Xcode 16+ syntax. Verified against Xcode 26.6.
- Mac App Store screenshot upload is out of scope — no `deliver`/`upload_to_app_store`
  automation exists in this repo today.

## Documentation

Add a "macOS App Store screenshots" subsection to CLAUDE.md's Commands section, covering the
lane, the shot list, where output lands, and the Retina caveat.
