# iOS 26 Layered App Icon — Inverted Monochrome SVG

Date: 2026-06-20

## Goal

Replace the Gemini-generated PNG layers in `Yana/Resources/AppIcon.icon` with
clean, theme-adaptive SVG layers reproducing the Yana profile mark (a
right-facing profile with a hair bun, round glasses, and a sparkle). The mark is
inverted relative to the source raster: instead of a white face on a solid
purple block, the silhouette becomes a **monochrome (white) foreground on full
transparency**, so Icon Composer auto-derives all four appearances —
**Default**, **Dark**, **Tinted**, **Clear** — and supplies each appearance's
backdrop itself.

## Source

Reference raster: a flat purple (`#725AE4`) screenshot containing a white
right-facing profile — head, hairline sweep, top bun, two round glasses (with
bridge and a dark pupil), spiral ear, small nose, smile, and an angled neck.
All facial/hair detail is rendered as the purple background showing through the
white. The decision was to reproduce the artwork **exactly**, so the vector is
produced by **tracing** the reference (potrace) rather than hand-drawing an
interpretation.

Note: a small four-point ✨ sparkle sits in the **bottom-right corner of the
screenshot** (≈ y 1360 of 1399) — this is UI chrome from the app that displayed
the image, **not** part of the logo. It is excluded.

## Layers

Canvas: **1024×1024** (Icon Composer working size). The traced white region —
which already contains every line-art feature as a hole — is one shape, so the
clean layered structure is a **purple background fill + a single white
foreground layer**:

1. **Background** — flat purple `#725AE4`, supplied via the `icon.json`
   top-level `fill` (an `automatic-gradient` from that color, visually flat,
   matching the reference). Icon Composer darkens it for Dark and substitutes
   system glass for Tinted/Clear.

2. **`Profile.svg`** — the traced white profile mark on full transparency, with
   all facial/hair features (hairline, both glass lenses + bridge + pupil, ear
   spiral, nose, smile) as **transparent holes** (potrace winding). Pure white
   on transparent, so Icon Composer recolors it per appearance. Fitted to the
   1024 canvas height-limited with ~10% margin, centered. `glass: true`.

The corner sparkle and the previously-planned additive "details" layer are
dropped — they were not part of the logo.

## `icon.json` changes

- Replace the three Gemini PNG layer entries with one SVG layer entry,
  `Profile.svg`, `glass: true`.
- Top-level `fill`: `automatic-gradient` of `#725AE4`
  (`extended-srgb:0.44706,0.35294,0.89412,1.00000`).
- Preserve the existing group `shadow` (`neutral`, opacity 0.5) and
  `translucency` (enabled, 0.5) settings, and `supported-platforms`.
- Remove the three Gemini PNG assets from `AppIcon.icon/Assets/`:
  - `Gemini_Generated_Image_tv7txptv7txptv7t.png`
  - `Gemini_Generated_Image_sm7goksm7goksm7g 2.png`
  - `Image.png`

## Theming behavior

Because the foreground is monochrome-on-transparent and features are cutouts
(not fixed-color overlays), Icon Composer derives:
- **Default** — system-tinted foreground over the default backdrop.
- **Dark** — light foreground over the dark backdrop.
- **Tinted** — monochrome recolor.
- **Clear** — glass/transparent backdrop, foreground retained.

No per-appearance SVG variants are authored.

## Verification

- `Profile.svg` parses as well-formed XML.
- It rasterizes to a shape that matches the reference mark over flat purple
  (silhouette, bun, hairline, two round glasses + pupil, ear, nose, smile,
  neck).
- Cutouts render as transparent holes (verified by compositing over both a
  light/purple and a dark background — confirms theming).
- `icon.json` remains valid JSON and references only `Profile.svg`; no
  dangling references to removed PNGs.
- The `.icon` bundle opens cleanly in Icon Composer with all four appearances
  rendering.

## Out of scope

- In-app logo usage (settings header, about screen).
- App Store marketing artwork.
- Icon animation.
- Per-theme hand-authored SVG variants.
- The bottom-right corner sparkle (screenshot UI chrome, not the logo).
- Splitting the glasses onto their own parallax layer (possible future depth
  enhancement; current build is background fill + single foreground layer).
