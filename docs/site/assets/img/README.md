# Site images

All images used by the site live here and are committed (GitHub Pages serves them
directly).

| File | Used on |
| --- | --- |
| `app-icon.svg` | brand mark + favicon (all pages) and the open-source section — reproduces the real Icon Composer app icon (owl on a purple gradient) |
| `social-preview.png` | Open Graph / Twitter card (2560×1280); also upload it under repo Settings → Social preview |
| `hero.png` | hero shot (`index.html`) — the reader view |
| `screen-timeline.png` | gallery — article list / timeline |
| `screen-search.png` | gallery — search |
| `screen-feeds.png` | gallery — feeds with tagged sources |

## Refreshing the screenshots

`hero.png` and the `screen-*.png` files are the **raw (unframed)** captures produced by
`fastlane screenshots`, taken from `fastlane/screenshots/en-US/` and downscaled to 640px
wide with `sips`:

```sh
fastlane screenshots            # regenerates fastlane/screenshots/en-US/*.png (+ de-DE)
SRC="fastlane/screenshots/en-US"; DST="docs/site/assets/img"
sips --resampleWidth 640 "$SRC/iPhone 17 Pro Max-01_Reader.png"   --out "$DST/hero.png"
sips --resampleWidth 640 "$SRC/iPhone 17 Pro Max-02_Timeline.png" --out "$DST/screen-timeline.png"
sips --resampleWidth 640 "$SRC/iPhone 17 Pro Max-04_Search.png"   --out "$DST/screen-search.png"
sips --resampleWidth 640 "$SRC/iPhone 17 Pro Max-03_Feeds.png"    --out "$DST/screen-feeds.png"
```

Use the raw captures, **not** the device-framed `*_framed.png` — the site rounds the
corners itself (`.shot` in `styles.css`). Keep images optimized (served as-is, no build
step); prefer PNG or WebP. There is no favicon file yet — add `favicon.png` here and link
it from each page's `<head>` if you want one.
