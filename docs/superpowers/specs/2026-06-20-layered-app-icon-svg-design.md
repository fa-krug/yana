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

Reference raster: a white right-facing profile (head, face curve, nose, chin,
neck, hair mass + top bun), with the facial features (round glasses, eye/brow,
nostril hint, smiling mouth, ear, hairline seam) drawn as the purple background
showing through, plus a small four-point ✨ sparkle bottom-right. The new vector
is a tidied interpretation of this raster, not a pixel-exact trace.

## Layers

Canvas: **1024×1024** (Icon Composer working size), pure white (`#FFFFFF`) fills
on transparency. The inversion drops the purple background block, so there are
two real layers.

1. **`profile-body.svg`** — the white profile silhouette as a single filled
   shape, with the facial features punched out as **transparent cutouts** using
   even-odd fill (`fill-rule="evenodd"`). Cutouts: round glasses (two
   lenses + bridge + a temple arm), eye/eyebrow, nostril hint, smiling mouth,
   ear, and the hairline seam between hair and face. Transparent everywhere
   outside the silhouette. Cutouts reveal whatever backdrop the active
   appearance provides, keeping the mark legible in every theme.

2. **`details.svg`** — additive white marks only: the bun wrap / parting line
   and the four-point ✨ sparkle. Transparent elsewhere. Sits above
   `profile-body`.

## `icon.json` changes

- Replace the three Gemini PNG layer entries with two SVG layer entries:
  - `profile-body` (bottom)
  - `details` (top)
- Both layers: `glass: true` so they pick up Liquid-Glass specular highlights.
- **Background:** transparent / no solid fill — the system tile shows through,
  which is the requested theme-fitting behavior.
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

- Each SVG parses as well-formed XML.
- Each layer rasterizes to the expected shape (per-layer PNG render) and a
  composite of both layers visually matches the reference mark (silhouette,
  bun, round glasses, smile, sparkle).
- Cutouts render as transparent holes (verified by compositing over a
  contrasting background).
- `icon.json` remains valid JSON and references only the two new SVG files;
  no dangling references to removed PNGs.
- The `.icon` bundle opens cleanly in Icon Composer with all four appearances
  rendering.

## Out of scope

- In-app logo usage (settings header, about screen).
- App Store marketing artwork.
- Icon animation.
- Per-theme hand-authored SVG variants.
