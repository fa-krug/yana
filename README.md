# Yana

A native SwiftUI app for iOS, iPadOS, and Mac (via Catalyst). Yana itself doesn't fetch or
parse anything — it's a thin, offline-first client for [Yana Server](https://github.com/fa-krug/yana-server),
a separate self-hosted project that does the actual work: pulling feeds, running scrapers,
talking to AI providers. You point this app at a server you run, it syncs down articles,
feeds, and images into a local SwiftData store so browsing works instantly offline, and it
pushes your actions (starring, reloading an article, kicking off a refresh) back up as API
calls. No credentials live on the device beyond a pairing token, and there's no feed/tag
editor in the app at all — that's handled by the server's own web UI, opened from Settings in
a WebView that reuses your login.

Yana is free and open source under the [MIT License](LICENSE). Browse the code, file a bug,
or request a new source at [github.com/fa-krug/yana](https://github.com/fa-krug/yana).

## Requirements

You'll need iOS 26.0+ or macOS 26.0+ (for the Mac Catalyst build), Xcode 26.0+, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38+ to generate the project. You'll also
need somewhere to point the app at — a running [Yana Server](https://github.com/fa-krug/yana-server)
instance, since Yana on its own has nothing to sync.

## Setup

Install XcodeGen if you don't already have it:

```bash
brew install xcodegen
```

Generate the Xcode project and open it:

```bash
xcodegen generate
open Yana.xcodeproj
```

Then select the **Yana** scheme and run it, either on an iOS/iPadOS simulator or device, or
on **My Mac (Mac Catalyst)**.

## How It Works

On first launch you enter your server's URL and sign in through a system browser sheet
(`ASWebAuthenticationSession`, so passkeys from iCloud Keychain work). That gets you a Bearer
token in the Keychain — nothing else to configure on the phone.

From there the app is mostly just a mirror of what's on the server. It syncs articles, feeds,
and images down and stores them in SwiftData; a full sync also backfills article bodies and
their images eagerly, so once you've synced, everything works with no connection at all. All
the actual feed/tag setup and AI provider configuration happens on the server's web UI, opened
from Settings › Manage Feeds & Tags.

The home screen is an endless timeline of every article: read ones first, oldest to newest,
then unread ones the same way, so the boundary between the two blocks is always the next
thing worth reading. Swipe in either direction and it remembers where you left off. A filter
button lets you toggle tags on and off — tag membership always reflects the feed's current
state on the server rather than a snapshot from when the article arrived — plus a "Starred
Only" switch.

Pulling down on the reader triggers a full refresh on the server ("Update All"); swiping an
article or using the reader's overflow menu re-fetches just that one ("Reload"). Both work the
same way under the hood: the app kicks off the job, waits for it to finish server-side, then
syncs the result down.

Articles can be read aloud in a voice matching their language, with lock-screen and Control
Center controls, and summarized either by your server's configured AI provider or by
on-device Apple Intelligence, whichever you pick in Settings. A summary shows up as its own
block right below the article header.

## Features

Device pairing keeps everything server-driven — the app has no aggregation logic of its own,
just a sync layer talking to `/api/v1/articles/sync` and `/api/v1/feeds`. On top of that
there's the endless timeline with remembered position, live tag filtering, native block
rendering for article bodies, starring, and the Update/Reload actions described above, plus
server-side retention so old articles clean themselves up without any client involvement.
Background refresh runs opportunistically through `BGAppRefreshTask`/`BGProcessingTask` on
iOS and a repeating loop on Mac. Beyond that there's full-text search across title, content,
author, and feed name; opt-in notifications for new articles after a background sync;
read-aloud with lock-screen controls; AI summarization from either the server or Apple
Intelligence; and a proper native Mac app with its own two-column window layout rather than a
scaled-up iPad view.

Still on the list: Face ID/Touch ID protection, multiple independent local libraries, a share
extension for adding feeds, a real iPad multi-column layout, and home screen widgets.

## Requesting a New Source

Aggregators — RSS/Atom, full websites, site-specific scrapers, Reddit, YouTube, podcasts, and
so on — live entirely on the [Yana Server](https://github.com/fa-krug/yana-server) side now,
so there's no source-specific code in this app to touch. In the app, Settings › About ›
Suggest a Source or Report an Issue opens the issue board directly; on the web you can open a
new issue at [github.com/fa-krug/yana/issues](https://github.com/fa-krug/yana/issues). Include
the site's URL and, if you have it, a link to its feed or the exact page you want followed —
the more specific the request, the quicker it gets added.

## Project Structure

```
Yana/
  YanaApp.swift             # App entry point; creates the SwiftData ModelContainer
  ContentView.swift         # Root view; opens directly into the timeline reader
  Models/                   # SwiftData @Model types (Feed, Tag, Article), settings
  Networking/               # YanaAPIClient, block-decoding, run/job-event wire types, SSE parsing
  Services/                 # DevicePairing, SyncEngine/SyncWriter, ArticleActions, ImageStore, AI providers
  Reader/                   # Native SwiftUI block renderer, pager, Mac Catalyst windowing (Reader/Mac/)
  Views/                    # SwiftUI views (settings, onboarding, management WebView)
  Utilities/                # Constants and extensions
  Resources/                # Asset catalogs, string catalog
  Entitlements/             # iOS/Mac entitlements
docs/app-store/             # App Store listing copy (EN/DE descriptions + keyword files)
docs/site/                  # GitHub Pages marketing + legal site (yana.fa-krug.de)
project.yml                 # XcodeGen project definition
LICENSE                     # MIT license
```

## Tests

```bash
xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`YanaTests/` has the unit tests, written with the Swift Testing framework. `YanaUITests/`
covers UI flows with XCTest, including the flows that capture the App Store screenshots below.

## App Store Screenshots

For iPhone (English + German, 6.9″ `iPhone 17 Pro Max`), framed and captioned:

```bash
brew install fastlane   # first time only
fastlane screenshots
```

For the Mac App Store (English + German, 2880×1800):

```bash
fastlane mac screenshots_mac
```

Both lanes run against an offline content fixture (`ScreenshotSeed`, DEBUG-only, gated by the
`-UITEST_SCREENSHOTS` launch argument), so nothing is fetched from real feeds and there's no
licensing exposure. The iPhone lane adds a device frame and localized captions under
`fastlane/screenshots/{en-US,de-DE}/`; the Mac lane just captures plain window shots, per Mac
App Store convention, under `fastlane/screenshots_mac/{en-US,de-DE}/`. `CLAUDE.md` has the
full pipeline details and the codesigning gotchas for the Mac lane.

## Architecture

The UI is SwiftUI throughout, shared across iOS, iPadOS, and Mac Catalyst, written in Swift 6
with strict concurrency and `@MainActor` everywhere it matters. SwiftData is the local,
offline-first mirror of whatever state the server has. Networking goes through
`YanaAPIClient`, a thin typed wrapper over the server's `/api/v1/**` REST API; `SyncEngine`
and `SyncWriter` handle pulling articles, feeds, and images down and applying local writes,
while `ArticleActions` and `UpdateAndSync` push user-triggered actions up and poll them for
completion. Auth is device pairing via `ASWebAuthenticationSession`, with the resulting Bearer
token kept in the Keychain, device-local and not synced through iCloud. The project itself is
generated from `project.yml` via XcodeGen, and code quality is enforced with SwiftLint and
SwiftFormat.

## Related Projects

[Yana Server](https://github.com/fa-krug/yana-server) is the self-hosted backend this app
pairs with — it's the one actually doing the aggregation, scraping, and AI-provider calls.

## License

Yana is released under the [MIT License](LICENSE). Source and issue tracker:
[github.com/fa-krug/yana](https://github.com/fa-krug/yana).

## Acknowledgements

Thanks to the [NetNewsWire](https://netnewswire.com) team, whose clean reader view inspired
Yana's article presentation.
