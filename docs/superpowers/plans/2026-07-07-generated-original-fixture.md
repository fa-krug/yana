# Generated Original Screenshot Fixture — Plan (pivot)

> Supersedes the real-content approach in `2026-07-06-real-content-fixture.md`. To avoid any
> third-party licensing/trademark exposure, the fixture becomes **fully original**: invented
> feed names, hand-authored article text, and **generated** lead images + feed logos. Nothing
> is fetched or committed from real feeds.

## Why

Using real feeds' verbatim titles, article text, thumbnails, and brand logos in the committed
fixture (and thus the App Store screenshots) is a licensing/trademark risk. Regenerating clean,
original content removes it — and generating per-feed logo tiles also fixes the earlier
"globe placeholder" issue (real favicons never reliably loaded in time).

## Decisions (from the user)

- **Feed names:** invented/original (no real brands).
- **Images:** stylized/abstract, generated offline (no photos). Lead images = tasteful
  gradient/abstract editorial graphics; logos = colored monogram tiles.

## Architecture

Return to a **pure code-authored seed** (no network, no committed binaries, no manifest):
`ScreenshotSeed` builds feeds/articles at seed time, generating each lead image and each feed
logo in-process and storing them via `ImageStore.storeData` (content-addressed → `yana-img://`
refs resolve). This removes the collector, the snapshot model, and the committed
`Yana/Resources/ScreenshotFixture/` entirely.

## Original content

Five invented feeds (distinct tags for a colorful Feeds shot):

| Feed | Tag | Color | Monogram |
|------|-----|-------|----------|
| Byte Report | Tech | #2E77D0 | BR |
| The Daily Brief | News | #D0392E | DB |
| Overtake | Video | #7A2ED0 | OV |
| The Commons | Community | #D07A2E | TC |
| Offline Hours | Audio | #2EB8D0 | OH |

~11 hand-authored articles (all original). Hero (anchor) = Byte Report #0 with lead image +
summary + multi-paragraph body. Search shot queries **"battery"** (present in ≥2 titles).

## Tasks

- **Task A — generators.** `ScreenshotImageFactory` (lead images: multi-stop gradient +
  subtle geometric motif + bottom vignette, deterministic by index) and `ScreenshotLogoFactory`
  (rounded-square tile in a tag color with a white monogram). Both DEBUG, `UIGraphicsImageRenderer`,
  return JPEG/PNG `Data`. Unit tests: non-empty, correct magic bytes, deterministic.
- **Task B — seed rewrite + cleanup.** Rewrite `ScreenshotSeed` to author the feeds/articles
  above, generating a lead image per article and a logo per feed (`storeData` → `feed.logoHash`).
  Produce bodies via `BlockParser.blocks(fromHTML:)`. DELETE `ScreenshotFixtureCollector.swift`,
  `ScreenshotFixture.swift`, `YanaTests/ScreenshotFixtureTests.swift`, and
  `Yana/Resources/ScreenshotFixture/`; remove the collector wiring + the entity-decode helper
  (authored text is clean). Update `ScreenshotSeedTests`. Keep the `-UITEST_SCREENSHOTS` gate +
  idempotency.
- **Task C — UITest + docs.** Set the `03_Search` query to "battery"; keep the logo settles.
  Rewrite the CLAUDE.md/README screenshot sections to describe the fully-generated fixture
  (drop collector/snapshot/real-content/refresh material). Dismiss the RSS-entity task if the
  decode workaround is gone. Note the app-level RSS-entity bug still stands on its own.
- **Task D — re-capture + verify.** Erase sim, `fastlane screenshots`; confirm all 4 shots:
  original text, generated lead images, generated per-feed logos (no globes), working search.

## Notes
- The standalone RSS title entity-decode bug (task chip) remains valid on its own merits — the
  fixture no longer needs the seed-side workaround, but real feeds still show raw entities.
- No committed image binaries after this pivot.
