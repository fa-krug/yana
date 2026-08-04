# Pre-2.0 Server Migration Notice

**Date:** 2026-08-04
**Status:** Approved design, ready for implementation plan

## Problem

Yana 2.0.0 introduces a hard dependency on a companion server
([yana-server](https://github.com/fa-krug/yana-server)) for feed aggregation. The on-device,
server-free architecture Yana shipped with through 1.1.0 is going away. Everyone who installed
Yana before this update needs to be told, once, in-app:

- Yana now requires the Yana Server to function, with a link to learn more.
- If they don't want to run a server, Yana 1.1.0 — the last fully self-contained release — is
  open source and can be built from source.
- If they'd rather stop using Yana entirely, they can email for a refund.

Anyone who installs Yana fresh at 2.0.0+ never ran the old self-contained flow, so the notice is
meaningless to them and must never appear for those installs.

## Goal

A dismissable full-screen notice shown once at launch to devices that already completed
onboarding before this feature existed, plus a way to bring it back on demand from Settings —
without adding a version-number tracking system (none exists in this codebase today) and without
ever showing it to a fresh 2.0+ install.

## Decisions

| Decision | Choice |
| --- | --- |
| "Existing user" detection | No version tracking added (see rationale below). A device is classified exactly once, ever, at the first launch that runs this code: `isPreServerMigrationUser = hasCompletedOnboarding`, captured *before* that launch's onboarding can run. Guarded by a one-time flag so it is never recomputed. |
| Presentation | Full-screen cover, styled like `WelcomeView` — matches the weight of the announcement and gives room for two links. |
| Auto-show trigger | `isPreServerMigrationUser && !hasDismissedServerMigrationNotice`, checked in `ContentView.onAppear`, next to the existing welcome-onboarding check. |
| Dismiss | Sets `hasDismissedServerMigrationNotice = true`. Never auto-shows again after that. |
| Restore | A **new, separate** row in Settings → About, visible only when `isPreServerMigrationUser`. Re-shows the notice on demand. The existing "Show Welcome Screen Again" row (`AboutSettingsSection.swift:33-40`) is left untouched — it's general onboarding replay, shown to everyone, unrelated to this feature. |
| Mac Catalyst | Its own `WindowGroup` (`WindowID.serverNotice`), mirroring `WelcomeWindowRoot`'s singleton-window pattern, since `Window(id:)`/`Settings` scenes don't compile under Catalyst. |
| Marketing page | New `docs/site/server.html`, bilingual EN/DE, matching the structure of `privacy.html`/`terms.html`. Real setup instructions pulled from `yana-server`'s own README — it is self-hosted only, no pricing/hosted plan exists. |
| Copy | Links to the new server page and the `v1.1.0` GitHub release (the self-contained escape hatch); offers a refund via `info@fa-krug.de`. |

### Why no version-number system

Nothing in this codebase persists "app version at last launch" today (`AppInfo.version` is
display-only). Rather than add one just for this, the classification only needs a yes/no answer
to "did this device already go through onboarding under the old, server-free flow?" —
`hasCompletedOnboarding`, read exactly once, before this build's own onboarding could ever set it.
That is a strictly simpler, equally correct signal: a fresh 2.0+ install has `hasCompletedOnboarding
== false` at that first check, an upgrading install has `true`. No app-version comparison needed.

## Architecture

### `AppSettings` additions (`Yana/Models/AppSettings.swift`)

Three new persisted, device-local flags, following the existing `hasSeenFullscreenHint` /
`hasCompletedOnboarding` pattern (plain `UserDefaults`-backed, `@Observable` access/mutation
tracking):

- `hasEvaluatedServerMigrationEligibility: Bool` (default `false`) — flips to `true` the first
  time the check below runs, and never again.
- `isPreServerMigrationUser: Bool` (default `false`) — set once, per the rule above.
- `hasDismissedServerMigrationNotice: Bool` (default `false`) — set when the notice is dismissed.

None of these are candidates for `SettingsCloudSync`'s allow-list — they're per-device launch
bookkeeping, same tier as `hasCompletedOnboarding` itself (which is also not synced).

### `ContentView.swift` wiring

Add a block to the existing `.onAppear`, evaluated before the welcome check (order doesn't
functionally matter since the two conditions are mutually exclusive in practice, but keeping the
one-time evaluation first is clearest to read):

```swift
if !settings.hasEvaluatedServerMigrationEligibility {
    settings.isPreServerMigrationUser = settings.hasCompletedOnboarding
    settings.hasEvaluatedServerMigrationEligibility = true
}
if settings.isPreServerMigrationUser, !settings.hasDismissedServerMigrationNotice {
    if isMac {
        openWindow(id: WindowID.serverNotice, value: true)
    } else {
        appState.showServerMigrationNotice = true
    }
}
```

`AppState` gets a new `var showServerMigrationNotice = false`, and `ReaderScreen`'s host
(`ContentView`, iOS branch) gets a second `.fullScreenCover(isPresented:
$appState.showServerMigrationNotice)` alongside the existing welcome cover, presenting
`ServerMigrationNoticeView`.

### New view: `Yana/Views/ServerMigrationNoticeView.swift`

A single-screen (no paging) view styled like `WelcomeView`'s content — icon/heading, body text
with two `Link`s, a primary dismiss button. Takes an `onDismiss: () -> Void` closure; the
presenter is responsible for persisting `hasDismissedServerMigrationNotice = true` and closing.

Copy (English; German added to `Localizable.xcstrings` per the project's translation rule):

> **Yana Now Requires a Server**
>
> Starting with this version, Yana needs to connect to a Yana Server to fetch and manage your
> feeds and articles. [Learn more about the Yana Server →](https://yana.fa-krug.de/server.html)
>
> Would rather not switch? Yana 1.1.0 — the last fully self-contained, server-free release —
> remains open source. You're welcome to build and run it yourself:
> [github.com/fa-krug/yana/releases/tag/v1.1.0](https://github.com/fa-krug/yana/releases/tag/v1.1.0)
>
> Don't want to use Yana anymore? Email
> [info@fa-krug.de](mailto:info@fa-krug.de) and I'll arrange a refund.
>
> **[Got It]**

### Mac: `Yana/Reader/Mac/ServerMigrationNoticeWindowRoot.swift` + `WindowID.serverNotice`

Mirrors `WelcomeWindowRoot` exactly:

```swift
struct ServerMigrationNoticeWindowRoot: View {
    @State private var settings = AppSettings()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ServerMigrationNoticeView(onDismiss: {
            settings.hasDismissedServerMigrationNotice = true
            dismiss()
        })
        .toggleStyle(.switch)
        .onAppear {
            if settings.hasDismissedServerMigrationNotice { dismiss() }
        }
    }
}
```

The `onAppear` guard matters for the same reason it matters on `WelcomeWindowRoot`: Mac Catalyst
can restore a window that was open at last quit, and this closes it immediately if it's already
been dismissed since. `YanaApp.swift` gets a third `WindowGroup(id: WindowID.serverNotice, for:
Bool.self)` alongside `.settings`/`.welcome`, same `.defaultSize`-style declaration.

### About section restore row (`AboutSettingsSection.swift`)

New optional callback, new row, gated on eligibility (the section already owns an `AppSettings`
instance, so no extra plumbing needed to read the flag):

```swift
var onShowServerNotice: () -> Void = {}
...
if settings.isPreServerMigrationUser {
    Button {
        settings.hasDismissedServerMigrationNotice = false
        onShowServerNotice()
    } label: {
        Label("Server Update Notice", systemImage: "server.rack")
            .labelStyle(.tintedIcon(.blue))
    }
    .accessibilityIdentifier("settings.showServerNotice")
}
```

Resetting `hasDismissedServerMigrationNotice` before calling the callback both re-presents the
notice now *and* satisfies the Mac window's self-close guard (without the reset, a restored
window would immediately close itself). `SettingsScreenView` (iOS) and `MacSettingsWindow` (Mac)
each thread the new callback through exactly like they already thread `onRestartOnboarding`:
iOS defers to after the Settings sheet dismisses (`restartOnboardingPending`-style flag →
`appState.showServerMigrationNotice = true`); Mac calls `openWindow(id: WindowID.serverNotice,
value: true)` then `dismiss()`.

### Localization

New keys (title, body incl. both links' display text, button, About row label) added to
`Yana/Resources/Localizable.xcstrings` in English and German, `"state": "translated"`, following
Apple-style German (infinitive, no Du/Sie). No count-bearing strings, so the plural-agreement
rules don't apply here.

### Marketing site: `docs/site/server.html`

New bilingual page (EN/DE spans, same `lang-en`/`lang-de` + `assets/app.js` toggle pattern as
`privacy.html`/`terms.html`), linked from the in-app notice and added to the site's nav. Content
drawn from `yana-server`'s actual README — no invented features or pricing:

- **What it is:** a self-hosted, open-source RSS/YouTube/Reddit/podcast aggregator server that
  powers the Yana iOS/Mac client's feed sync — a single process (Next.js/React/TypeScript +
  SQLite via Drizzle/better-sqlite3), no Redis, no separate worker container.
- **Accounts:** passkey sign-in; an administrator account is created on first start; there is no
  public self-service sign-up (an admin provisions each user).
- **Install — npm:**
  ```bash
  npm install
  npm run dev
  ```
  then open `http://localhost:3000`.
- **Install — Docker:**
  ```bash
  mkdir -p data media && chown -R 1001:1001 data media
  docker compose up --build
  ```
  then open `http://localhost:3000`.
- **Configuration:** copy `.env.example` to `.env`; set `BETTER_AUTH_SECRET` (e.g. `openssl rand
  -base64 32`) before any real deployment; optional `DATABASE_PATH`, `MEDIA_PATH`,
  `PASSKEY_RP_ID`, `PUBLIC_URL`, `TZ`, `PORT`. The default admin account (`admin@admin.com` /
  `admin`) must be changed immediately after first login.
- **License / cost:** MIT-licensed, free, self-hosted only — no hosted/managed plan is offered.
- Link to [github.com/fa-krug/yana-server](https://github.com/fa-krug/yana-server).

### Testing

`YanaTests/` gets a new test file pinning the pure state-transition logic (extracted as a small
free function/struct so it's testable without SwiftUI, mirroring how `DiagnosticsReveal` and
`ImagePrunePlan.decide` are tested):

- First-ever evaluation with `hasCompletedOnboarding == true` → `isPreServerMigrationUser ==
  true`, `hasEvaluatedServerMigrationEligibility == true`.
- First-ever evaluation with `hasCompletedOnboarding == false` → `isPreServerMigrationUser ==
  false`.
- A second evaluation attempt (already evaluated) never changes `isPreServerMigrationUser`, even
  if `hasCompletedOnboarding` has since become `true`.
- Dismiss → `hasDismissedServerMigrationNotice == true`; restore (from About) → resets it to
  `false` and only when `isPreServerMigrationUser == true` (the row doesn't exist otherwise, but
  the underlying logic is pinned directly too).

## Out of scope

- The actual client integration with `yana-server` (pairing, auth, sync) — separate, much larger
  effort tracked in the 2.0.0 milestone itself; this notice only announces the requirement.
- Any change to the brand-new-install onboarding flow (`WelcomeView`) for 2.0+ — how a fresh
  install sets up its server connection is a separate design.
