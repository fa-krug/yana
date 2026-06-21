# iOS 26 Layered App Icon — Owl Monochrome SVG

Date: 2026-06-20

## Goal

Provide the app icon foreground as a clean, theme-adaptive SVG: a pair of **big
round glasses** (the "reader" mark) rendered as a **monochrome (white)
foreground on full transparency**, so Icon Composer auto-derives all
appearances — **Default**, **Dark**, **Tinted**, **Clear** — and supplies each
appearance's backdrop itself.

## Design

Canvas: **1024×1024** (Icon Composer working size). A single white foreground
layer (`Profile.svg`) over a purple background fill.

The mark is a stylized **owl** built from oversized round glasses geometry:

- **Two round eyes** — circles (r ≈ 185), drawn as rings: each eye is one
  `<path>` with an outer and inner circle combined under `fill-rule="evenodd"`,
  so the iris ring is a **transparent gap** (the background shows through).
- **Pupils** — a filled white disc (r ≈ 58) centered in each eye, so the mark
  reads as eyes rather than empty lenses.
- **Beak** — a bold downward-pointing shape (flat/wide top, gently convex sides
  tapering to a rounded point) centered between the eyes, with clear spacing
  from the eye rings (where a glasses bridge would sit).
- No eyebrows / feather tufts, no temple arms / handles.

Everything is pure white on transparency. The pupils and beak are separate
`<path>` elements that union with the eye rings — they do not rely on cross-path
`evenodd` interaction (SVG fill rules apply per path).

## Theming behavior (background is adjustable, frame adapts)

- **Background** — supplied via the `icon.json` top-level `fill` as an
  `automatic-gradient` of the brand purple `#725AE4`
  (`extended-srgb:0.44706,0.35294,0.89412,1.00000`). Icon Composer adapts it
  across appearances (light purple → dark purple) and substitutes system glass
  for Tinted/Clear. The single fill color is the one editable knob.
- **Foreground** — monochrome-on-transparent with `glass: true`, so Icon
  Composer recolors the owl per appearance and the frame auto-contrasts
  against the background (purple frame on the light backdrop, white frame on the
  dark backdrop).

No per-appearance SVG variants are authored.

## `icon.json`

- One SVG layer entry: `Profile.svg`, `glass: true`.
- Top-level `fill`: `automatic-gradient` of `#725AE4`.
- Preserve the group `shadow` (`neutral`, opacity 0.5), `translucency`
  (enabled, 0.5), and `supported-platforms`.

## Verification

- `Profile.svg` parses as well-formed XML.
- Rasterizes to an owl (two round eyes with pupils, a central downward beak)
  with the iris rings transparent — confirmed by compositing over both a
  light-purple and a dark-purple background.
- `icon.json` remains valid JSON and references only `Profile.svg`.

## Out of scope

- In-app logo usage (settings header, about screen).
- App Store marketing artwork.
- Icon animation.
- Per-theme hand-authored SVG variants.
