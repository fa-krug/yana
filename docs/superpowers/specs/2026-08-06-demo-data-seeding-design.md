# Demo data seeding for skipped server pairing

## Problem

Onboarding's server step (`OnboardingServerPage`) currently has no way forward except pairing —
"Sign In" is the only button. A user who wants to try the app before setting up a Yana Server has
no path in, and would otherwise land on an empty timeline forever (there's no client-side feed
creation any more; everything comes from a paired server). We want a "Skip for now" path that
seeds realistic demo content and clearly marks it as demo data until the user pairs a real server.

## Design

### 1. "Skip for now" button

`OnboardingServerPage` gets a second button alongside "Sign In":

- Seeds the demo library (see §2) into `AppContainer.shared.mainContext`.
- Sets `AppSettings.hasSkippedServerPairing = true`.
- Calls the same `onPaired()` continuation `WelcomeView` already wires up for a successful pair,
  advancing to the `.aiMode` step. Skipping and pairing are just two ways to leave this step; the
  rest of onboarding (AI mode → Finish) doesn't need to know which happened.

### 2. Demo content: reuse `ScreenshotSeed` verbatim

`ScreenshotSeed`, `ScreenshotImageFactory`, and `ScreenshotLogoFactory`
(`Yana/Utilities/Screenshot*.swift`) already author a small library of fully original,
network-free feeds/articles/images for App Store screenshots, gated behind the
`-UITEST_SCREENSHOTS` launch argument, and `ScreenshotSeed.seed(into:)` is already idempotent
(bails if any `Feed` row exists). Remove the `#if DEBUG` wrapper from all three files so they
compile into release builds too — their own launch-argument/call-site gating is unchanged, so
screenshot capture behavior is unaffected. The skip button calls
`await ScreenshotSeed.seed(into: AppContainer.shared.mainContext)` directly. No second content
library is authored or maintained.

### 3. Don't re-prompt for pairing every launch after a deliberate skip

`WelcomeGate.neededStep(hasCompletedOnboarding:isPaired:)` currently sends any onboarded-but-unpaired
device back into the `.server` step — correct for "pairing was revoked," wrong for "user chose demo
mode." Add a third parameter:

```swift
static func neededStep(
    hasCompletedOnboarding: Bool,
    isPaired: Bool,
    hasSkippedServerPairing: Bool
) -> WelcomeView.Step? {
    if !hasCompletedOnboarding { return .welcome }
    if !isPaired && !hasSkippedServerPairing { return .server }
    return nil
}
```

`ContentView.presentWelcomeIfNeeded` passes `settings.hasSkippedServerPairing` through. A device
that was genuinely paired and lost its session (`hasSkippedServerPairing == false`) keeps today's
behavior exactly.

### 4. Persistent demo-mode banner

A new `DemoModeBanner` SwiftUI view (`Yana/Views/DemoModeBanner.swift`), shown via
`.safeAreaInset(edge: .top)`:

- In iOS `ReaderScreen`, whenever `settings.hasSkippedServerPairing == true`.
- In Mac `MacRootView`, same condition.

Content: a compact bar — "You're viewing demo content." / "Pair a Yana Server to sync your real
feeds." plus a **"Pair Now"** button and a dismiss (×). "Pair Now" reopens `WelcomeView` at
`.server`, reusing the exact mechanism `AboutSettingsSection`'s existing "Show Welcome Screen
Again" row already drives (`appState.welcomeInitialStep = .server; appState.showWelcome = true` on
iOS, `openWindow(id: WindowID.welcome, value: true)` on Mac).

Dismissal is per-launch, not permanent: a new `AppSettings.hasDismissedDemoBanner` flag hides the
banner for the rest of the current session but is not read at launch, so it reappears next time the
app is opened. This mirrors how a permissions/nag banner should behave — persistent enough to not
be forgotten, dismissible enough to not be annoying mid-session. (Concretely: the flag is set on
dismiss and cleared in `YanaApp`'s launch path alongside other one-time launch resets, the same
place `UITestReset`/`DebugSeed` already hook into.)

### 5. Cleaning up demo data when a real server is later paired

`OnboardingServerPage`'s `DevicePairingView.onPaired` closure is the single call site where a
device token is ever saved (both first-run onboarding and the "Show Welcome Screen Again" /
revoked-session re-entry go through it). Extend it: if `settings.hasSkippedServerPairing` was
`true` at the moment pairing succeeds, wipe the local library *before* `WelcomeView.finish()`'s
first sync runs, then clear the flag.

The wipe logic already exists in `UITestReset` (delete all `Article`, `Feed`, `Tag`, clear the
timeline anchor) but is `#if DEBUG`-gated and tied to a launch argument. Extract the deletion body
into a small shared, non-DEBUG helper — e.g. `LocalLibraryReset.wipe(context:)` in
`Yana/Utilities/LocalLibraryReset.swift` — called by both `UITestReset.resetIfRequested` (DEBUG,
launch-argument-gated, unchanged behavior) and the new pairing-success cleanup (release-safe,
flag-gated).

## Out of scope

- No new demo content beyond what `ScreenshotSeed` already authors.
- No changes to `SyncEngine`/`SyncWriter`/background refresh — an unpaired device already no-ops
  everywhere (`AuthenticatedClient.current() == nil`); demo mode doesn't change that contract, it
  just adds seeded local content and a flag/banner on top of the existing "not paired" state.
- No Settings-screen changes beyond what already exists ("Show Welcome Screen Again" is already a
  sufficient path back into pairing; the banner's "Pair Now" is a shortcut to the same mechanism).

## Testing

- `WelcomeGate` unit tests: add cases for `hasSkippedServerPairing == true` (no `.server` step) and
  confirm the revoked-session case (`hasSkippedServerPairing == false`, `isPaired == false`) is
  unchanged.
- `LocalLibraryReset` unit test: wipes articles/feeds/tags/anchor from a populated context.
- `ScreenshotSeed`/factories: existing tests (`ScreenshotSeedTests.swift`) continue to pass unchanged
  now that the `#if DEBUG` gate is gone — verify they still compile/run in a DEBUG test target.
- Manual/UI check: skip pairing in onboarding → demo articles appear, banner shows; dismiss banner
  → reappears on relaunch; "Pair Now" → pair against a real server → demo content is gone and real
  sync content appears; banner no longer shows.

## Localization

New user-facing strings (banner text, "Skip for now", "Pair Now") need `en`/`de` entries in
`Localizable.xcstrings` per project convention.
