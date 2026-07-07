# Real-Content Screenshot Fixture — Plan (addendum)

> Extends `2026-07-06-appstore-screenshots.md`. Replaces the synthetic `ScreenshotSeed`
> content with **real feed content collected once** and frozen into a committed, offline
> snapshot. The screenshot run itself still never hits the network.

## Goal

Screenshots show authentic titles, article bodies, real image thumbnails, and real feed
logos — collected once from live English RSS feeds, serialized to a bundled snapshot, and
replayed offline by the fixture.

## Architecture (two phases)

**Phase 1 — Collect (DEBUG, one-time, hits network).** A new launch mode
`-COLLECT_SCREENSHOT_FIXTURE` runs the app's real aggregators against a hardcoded list of
English RSS feeds using `AggregationService.forceReload(feed:)` (bypasses the 60-day intake
window + daily cap), selects a curated subset, and exports a `ScreenshotFixture` manifest
(JSON) + the referenced image bytes into the app container. The developer pulls those files
out of the simulator and commits them under `Yana/Resources/ScreenshotFixture/`.

**Phase 2 — Seed (offline, screenshot time).** `ScreenshotSeed` (still gated by
`-UITEST_SCREENSHOTS`) loads the bundled manifest + images, re-inserts the image bytes into
`ImageStore` via `storeData`, recreates the Feeds (incl. `logoHash`) + Tags + Articles
(blocks, summary, spread `createdAt`, parked anchor). No network.

## Feeds (English tech mix, all keyless `.feedContent` RSS/Atom)

| Feed name | Tag | URL |
|-----------|-----|-----|
| The Verge | Tech | `https://www.theverge.com/rss/index.xml` |
| Ars Technica | Tech | `https://feeds.arstechnica.com/arstechnica/index` |
| Marques Brownlee | Video | `https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ` |
| r/apple | Community | `https://www.reddit.com/r/apple/.rss` (fallback `https://hnrss.org/frontpage` if 429) |
| Accidental Tech Podcast | Audio | `https://atp.fm/rss` |

Tag colors reuse the current palette (Tech `#2E77D0`, Video `#7A2ED0`, Community `#D07A2E`,
Audio `#2EB8D0`, plus News `#D0392E` if a 5th tech feed replaces one).

## Key facts (from stack API map)

- `AggregationService(context:)` → `forceReload(feed:) async -> Int` bypasses intake
  window + cap; upserts real `Article`s into the passed `ModelContext`; sets `feed.logoHash`
  (real favicon) via the default logo resolver.
- `Article`: `title`, `identifier`, `url`, `author`, `date`, `createdAt`, `summary: String`
  (`""` sentinel, NOT optional), `blocks: [Block]` (computed; `[Block]` is `Codable`),
  `iconURL`, `tags`, `feed`. Lead image = first `Block` if `.image` (no separate field).
- Body/lead/logo images live in `ImageStore.shared` as `<hash>.<ext>`; refs are
  `yana-img://<hash>`. Re-insert bytes with `ImageStore.shared.storeData(_:ext:) -> String`.
- Feed URL lives in `Feed.identifier`. `Feed(name:aggregatorType:identifier:)` +
  `feed.tags = [tag]`. `Feed.logoHash` is the logo ref.
- `Block`/`InlineRun`/`Embed`/`InlineStyle` are all `Codable`.

## Tasks

### Task A — `ScreenshotFixture` Codable DTOs
`Yana/Utilities/ScreenshotFixture.swift` (DEBUG). Structs:
`ScreenshotFixture { feeds: [Feed]; images: [Image]; anchorFeedIndex: Int; anchorArticleIndex: Int }`,
`Feed { name; identifier; tagName; tagColorHex; logoHash: String?; articles: [Article] }`,
`Article { title; url; author; summary; date: Date; blocks: [Block] }`,
`Image { hash; ext }`. All `Codable, Sendable`. TDD: encode→decode round-trip incl. a `[Block]`.

### Task B — `ScreenshotFixtureCollector` + `-COLLECT_SCREENSHOT_FIXTURE` wiring
`Yana/Utilities/ScreenshotFixtureCollector.swift` (DEBUG). On the launch arg: build an
in-memory `ModelContainer`; create the 5 feeds; `forceReload(feed:)` each; select up to 3
articles/feed that have a lead image (first block `.image`); derive a short `summary` from
each article's `plainText` (first ~180 chars, sentence boundary) when empty (real excerpt —
keeps the reader SUMMARY block populated); collect all referenced image hashes (block
`.image` refs + `feed.logoHash`), read their bytes+ext from `ImageStore.shared`; write
`manifest.json` + `images/<hash>.<ext>` to `FileManager…/Documents/ScreenshotFixture/`; log
the container path. Pick a hero (first feed/article with a strong lead image) as the anchor.
Handle a feed that returns nothing gracefully (log + skip). Verified by running it (network).

### Task C — Collect + commit the snapshot (operational, controller)
Run the collect mode on `iPhone 17 Pro Max`, pull `Documents/ScreenshotFixture/` from the
container (`xcrun simctl get_app_container … data`), commit under
`Yana/Resources/ScreenshotFixture/manifest.json` + `images/`. Add the resource folder to the
app target (XcodeGen already sources `Yana/`; confirm the folder is bundled). Verify the JSON
looks sensible (real titles, ≥~10 articles, logos present).

### Task D — Rewrite `ScreenshotSeed` to load the snapshot
`ScreenshotSeed.seed(into:)` loads `manifest.json` from `Bundle.main`, decodes
`ScreenshotFixture`, re-inserts each `images/<hash>.<ext>` into `ImageStore` via `storeData`,
recreates Feeds (name/identifier/logoHash) + Tags (name/color, deduped) + Articles
(title/url/author/summary/blocks; `createdAt` spread by index; `tags`), parks the anchor.
Keeps the `-UITEST_SCREENSHOTS` gate + idempotency. Remove the now-dead
`ScreenshotImageFactory` synthesis path from the seed (keep the file only if still used;
otherwise delete it). Update `ScreenshotSeedTests` to load a tiny committed test manifest OR
assert against the real one (≥ N feeds/articles, blocks non-empty, anchor resolves).

### Task E — Re-capture + verify (controller)
Erase sim, `fastlane screenshots`, inspect all 4 framed shots: real titles, real thumbnails,
real feed logos (no generic globes), summary once. Adjust feed/article selection if a shot
is weak.

### Task F — Docs
Update `CLAUDE.md` + `README.md`: the two-phase collect-once workflow, the
`-COLLECT_SCREENSHOT_FIXTURE` launch arg, where the snapshot lives, and how to refresh it.

## Notes / risks
- **Copyright:** real third-party titles + thumbnails appear in the store listing (user
  accepted). The committed image bytes are third-party content — acceptable for this repo per
  the user; revisit if the repo goes public.
- **`summary` is a real excerpt**, not an AI summary — noted in code + docs.
- **Reddit `.rss`** may 429 from some IPs; fall back to `hnrss.org/frontpage` (Community).
- **YouTube channel RSS** entries may lack an inline `<img>`; such articles won't have a lead
  image — they still contribute a real feed name + YouTube logo to the Feeds shot.
