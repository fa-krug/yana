# GitHub Pages Site — Design

Date: 2026-07-06

## Goal

A self-contained, bilingual (English + German) static marketing site for Yana,
built from the existing README and App Store copy, deployed to GitHub Pages. It
includes the legal pages (Privacy Policy, Impressum/Imprint, Terms of Use) and a
placeholder App Store download link. All images are placeholders to be swapped in
later.

## Constraints & principles

- **No external requests** — no CDN fonts, scripts, or trackers. System font stack
  only. This mirrors (and lets us truthfully claim) the app's privacy posture.
- **No build step** — plain HTML/CSS/JS, served as-is.
- **Reuse existing copy** — README + `docs/app-store/description-{en,de}.md`.
- **Light + dark** via `prefers-color-scheme`.
- **Responsive** — mobile-first, single-column collapses cleanly.

## File structure

```
docs/site/
  index.html          # landing page
  privacy.html        # Privacy Policy
  impressum.html      # Impressum / Imprint
  terms.html          # Terms of Use
  assets/
    styles.css        # shared styles + design tokens
    app.js            # language toggle
    img/README.md     # lists the image files to drop in later
.github/workflows/pages.yml   # deploy docs/site to GitHub Pages
```

## Bilingual mechanism

One set of pages, both languages inline. Every translatable element carries a
`lang-en` or `lang-de` class. `<html data-lang="…">` drives visibility via CSS:
`[data-lang="en"] .lang-de { display: none }` and vice-versa. A header EN/DE toggle
sets `data-lang`, persists to `localStorage`, and an inline `<head>` script applies
the stored/`navigator.language` choice before first paint (no flash). Default: EN.

## Landing page sections (copy from existing texts)

1. Header/nav — app-icon placeholder + "Yana", nav anchors, EN/DE toggle, "Coming
   to the App Store" badge (placeholder href `#`).
2. Hero — headline, subtext, App Store badge, hero screenshot placeholder.
3. Feature blocks — Beyond RSS · Fast native reader · Offline-ready · AI (Apple
   Intelligence + bring-your-own-key) · Read aloud · Tags & endless timeline ·
   Privacy-first · OPML/background/search/retention.
4. Screenshots gallery — labeled placeholder tiles.
5. Open source + credit — MIT, repo/issue links, NetNewsWire thanks.
6. Footer — GitHub, issues, Privacy, Impressum, Terms, License (→ GitHub on the
   repo), © 2026 Sascha Krug.

## Placeholders

Each image is a labeled dashed-border box (CSS, no binary asset needed) naming the
shot it will hold (e.g. "Screenshot: Reader"). `assets/img/README.md` lists the
expected filenames so replacement is drop-in. App Store badge links to `#`.

## Legal pages

- **Privacy Policy** — truthful from existing copy: on-device only; no account,
  login, or server; nothing leaves the device except a user-chosen AI provider;
  API keys in the Keychain; optional opt-in notifications; no analytics/tracking.
- **Impressum** — German-law site notice with placeholder name/address/email/phone
  fields (`[Your name]`, `[Street]`, …) for the owner to fill in.
- **Terms of Use** — plain-language terms plus the MIT "as is" / no-warranty
  disclaimer.

## Deploy

`.github/workflows/pages.yml` runs on push to `main`, uploads `docs/site` as a
Pages artifact, and deploys it. One-time manual step (documented, cannot be done
from here): repo **Settings → Pages → Source: GitHub Actions**.

## Design direction

Calm, reading-first. Serif display headings (system serif) over a sans body
(system sans). Warm off-white / ink palette with one muted accent; generous
whitespace; rounded feature cards; subtle borders over heavy shadows.
