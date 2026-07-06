# Site images

Drop the real images here, then replace the matching placeholder box in the HTML
(each placeholder is a `<div class="ph">…</div>` with a label naming the shot).

Expected files:

| File | Used on | Suggested size |
| --- | --- | --- |
| `app-icon.png` | header brand mark (`index.html`, all pages) | 60×60 (or SVG) |
| `hero.png` | hero screenshot (`index.html`) | ~640×1386 (9:16) |
| `app-icon-large.png` | open-source section (`index.html`) | ~800×600 |
| `screen-reader.png` | gallery — Reader | ~640×1386 (9:16) |
| `screen-timeline.png` | gallery — Timeline | ~640×1386 (9:16) |
| `screen-tags.png` | gallery — Tag filter | ~640×1386 (9:16) |
| `screen-settings.png` | gallery — Settings | ~640×1386 (9:16) |

To swap a placeholder, replace e.g.

```html
<div class="ph"><span class="lang-en">Screenshot: Reader</span>…</div>
```

with

```html
<img src="assets/img/screen-reader.png" alt="Yana reader view" style="border-radius: var(--radius-lg); width: 100%;" />
```

Keep images optimized (they are served as-is; there is no build step) and prefer
PNG or WebP. There is no favicon yet — add `favicon.png` here and link it from the
`<head>` of each page if you want one.
