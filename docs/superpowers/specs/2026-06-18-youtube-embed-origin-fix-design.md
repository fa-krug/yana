# Fix YouTube embed Error 153 (origin mismatch)

**Date:** 2026-06-18
**Status:** Approved

## Problem

YouTube videos embedded in the reader fail to play, showing:

> Video auf YouTube ansehen — **Fehler 153** — Fehler bei der Konfiguration des Videoplayers

(Error 153 / "video player configuration error").

The Yana **server** does not have this problem because it routes embeds through its own
proxy endpoint (`/api/youtube-proxy?v=ID`). The user asked us to replicate that proxy on
iOS.

## Diagnosis

The iOS app already emits the same embed markup the server's proxy serves —
`youtube-nocookie.com`, `enablejsapi=1`, `origin=…`, `referrerpolicy="strict-origin-when-cross-origin"`
(`EmbedRewriter.youTubeEmbedHTML`). The markup is not the problem; the **document origin is**.

Three "origins" are in play and they disagree:

| Layer | Value |
|---|---|
| WebView document origin (`loadHTMLString baseURL`, `ReaderWeb.pageBaseURL`) | `file://…/bundle/` → opaque |
| `<base href>` in `page.html` | the article's real URL (cosmetic; does **not** change `window.location.origin`) |
| `origin=` param fed to YouTube (`ReaderWeb.baseOrigin`) | `https://app.yana.local` |

YouTube's player validates the embedder's actual `window.location.origin` against the
declared `origin=` param. The real origin is the opaque `file://` origin; the declared one is
`app.yana.local`. They never match → **Error 153**.

### Why the server's proxy works

The proxy serves a wrapper page from a **real, stable origin** (`request.get_host()`) and sets
the YouTube iframe's `origin=` to **that same origin**. Real origin == declared origin → no
error. Crucially the host need not be public: the server's dev default `BASE_URL` is
`http://localhost:8000` and it still works. The mechanism is *origin consistency*, not
reachability.

The iOS app already declares `origin=https://app.yana.local` but never makes the document
actually load at that origin — it loads at `file://`. So the proxy is "half-built": the
declared origin exists, but the document that should carry it doesn't.

## Design

Make the article document actually have the origin it already claims, mirroring the server's
"serve from a consistent real origin" approach with a single fixed app origin.

- **Change `ReaderWeb.pageBaseURL`** from the `file://` bundle directory to
  `URL(string: "https://app.yana.local")!` — the same origin already declared in
  `ReaderWeb.baseOrigin`. `window.location.origin` then equals the `origin=` param on every
  embed → match → Error 153 resolved.
- **Update the doc comment** on `pageBaseURL`, which currently argues *for* the `file://`
  base; replace it with the origin-consistency rationale.
- **Nothing else changes.** Embed markup, the `origin=` param, `referrerpolicy`, and
  `<base href>` are untouched. Relative links continue to resolve against `<base href>` (the
  article's real URL) — the `<base>` tag governs relative resolution independently of the
  document origin — so link behaviour and `ReaderWeb.linkInterceptionScript` are unaffected.

### Why a single fixed origin (not per-article, not a custom scheme handler)

The server uses **one** fixed origin (its own host) for every embed, regardless of article.
A single fixed app origin is the faithful mirror and a one-value change, versus threading
each article's URL through the aggregation-time embed generation. A custom `WKURLSchemeHandler`
(the `yana-img://` pattern) would give a custom-scheme origin rather than the real `https`
origin the embed already declares, and is more machinery than needed.

## Risks / verification

This is an architectural change to how the reader document is loaded, so it must be verified
on the simulator rather than assumed:

1. **`yana-img://` images under an `https://` document.** Custom-scheme subresources could trip
   mixed-content blocking now that the document origin is `https` rather than `file://`. This is
   the primary risk to watch. (`yana-img://` is served by `ImageSchemeHandler` via
   `setURLSchemeHandler`.) If images break, the scheme-handler registration / response is where
   we address it.
2. **YouTube playback.** Confirm Error 153 is gone and a YouTube article actually plays.

No requests are made to `app.yana.local`: the document HTML is provided inline by
`loadHTMLString`, and relative subresources resolve against `<base href>` (the real article
URL), so the fake host is never contacted.

**Fallback** if verification surfaces an unfixable blocker: replace the inline iframe with a
click-to-play thumbnail that opens the video in `SFSafariViewController` / the YouTube app.

## Out of scope

- Per-article origins.
- A custom-scheme embed proxy / `WKURLSchemeHandler` for embeds.
- Changes to Dailymotion/other embeds beyond what the shared `pageBaseURL` change already
  confers (the fix is embed-agnostic).
- No new user-facing strings, so no `Localizable.xcstrings` changes are expected.
