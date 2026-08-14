# Remove server connection

## Problem

There is no way to un-pair a device short of reinstalling the app or revoking the session
server-side. A user who wants to stop syncing against a given Yana Server (switching servers for
good, decommissioning a self-hosted instance, or just wanting to go back to trying the app without
a server) has no in-app path to do that cleanly.

## Design

### 1. New destructive action in `ServerSettingsSection`

`ServerSettingsSection` (`Yana/Views/Config/Settings/ServerSettingsSection.swift`, shared by iOS
Settings and `MacSettingsWindow`) gets a second row below the existing server/re-pair row: a red
"Remove Server Connection" button. Shown only when the device is actually paired/configured
(`AuthenticatedClient.current() != nil`) — there's nothing to remove otherwise (including while
already in demo mode).

Tapping it presents a confirmation alert before doing anything irreversible:

- Title: "Remove Server Connection?"
- Message: "This deletes all articles stored on this device and switches to demo content until
  you pair a server again."
- Actions: "Remove" (destructive role) / "Cancel".

The message explicitly names both consequences — local data loss and the fallback to demo
mode — so the user isn't surprised by seeing sample articles afterward.

### 2. `ServerDisconnect` service

New `Yana/Services/ServerDisconnect.swift`, mirroring the shape of the existing `PairingSync`
(`Yana/Services/PairingSync.swift`), which performs the reverse transition using entirely existing,
already-tested building blocks:

```swift
enum ServerDisconnect {
    @MainActor
    static func disconnect(settings: AppSettings) {
        KeychainService.deleteDeviceToken()
        settings.serverBaseURL = ""
        LocalLibraryReset.wipe(context: AppContainer.shared.mainContext)
        settings.hasSkippedServerPairing = true
        Task {
            await ScreenshotSeed.seed(into: AppContainer.shared.mainContext)
        }
    }
}
```

Order matters: the token/URL are cleared and the library wiped synchronously (so
`AuthenticatedClient.current()` immediately resolves to `nil` and the UI reflects "not paired"
right away), then demo seeding runs as a fire-and-forget `Task` exactly like
`OnboardingServerPage.primaryAction`'s skip path already does.

This is the exact same machinery already built for onboarding's "Skip for now" demo-mode flow
(`docs/superpowers/specs/2026-08-06-demo-data-seeding-design.md`), just triggered from the opposite
direction (was paired → now skipped, instead of never paired → skipped). Nothing new is invented:

- `LocalLibraryReset.wipe` already deletes all `Article`/`Feed`/`Tag` and clears the timeline
  anchor + sync cursor.
- `ScreenshotSeed.seed(into:)` already authors the same network-free demo library shown to a user
  who skips pairing during onboarding, and is idempotent (bails if any `Feed` exists — irrelevant
  here since the wipe just ran, but worth noting no double-seed can happen).
- `AppSettings.hasSkippedServerPairing = true` already drives `DemoModeBanner`'s visibility
  (`hasSkippedServerPairing && !isPaired`) and `WelcomeGate.neededStep`'s "don't re-prompt for
  pairing" branch — so the user lands directly on a normal-looking demo timeline, not back in
  onboarding.

### 3. Nothing else changes

`SyncEngine`, `BackgroundRefreshManager`, and `ReadingPositionLiveSync` all already treat
"unpaired" (`AuthenticatedClient.current() == nil`) as a normal no-op/idle state — this is the
existing contract the demo-mode design already established, not something this feature needs to
add. `ReadingPositionLiveSync` in particular re-resolves its client on every reconnect attempt, so
it naturally idles once the token is gone with no explicit stop() call needed.

## Out of scope

- No server-side session revocation call — the server isn't told the device disconnected. (There
  is no such endpoint today; the token simply stops being presented.)
- No new demo content beyond what `ScreenshotSeed` already authors.
- No changes to onboarding, `WelcomeGate`, or `DemoModeBanner` — all already behave correctly once
  `hasSkippedServerPairing` flips to `true` outside of onboarding.

## Testing

- New `YanaTests/ServerDisconnectTests.swift`: given a populated context + a saved Keychain token +
  a non-empty `serverBaseURL`, after `disconnect()`: Keychain token is `nil`, `serverBaseURL` is
  empty, `hasSkippedServerPairing` is `true`, and the context has zero `Article`/`Feed`/`Tag` rows
  immediately (synchronously, before the demo-seed `Task` even needs to be awaited).
- Manual/UI check: pair a server → confirm "Remove Server Connection" is visible → tap it → confirm
  alert copy mentions both data deletion and demo mode → confirm → demo articles appear, demo
  banner shows, Settings' server row now offers to sign in again.

## Localization

New user-facing strings ("Remove Server Connection", the confirmation title/message, "Remove")
need `en`/`de` entries in `Localizable.xcstrings` per project convention.
