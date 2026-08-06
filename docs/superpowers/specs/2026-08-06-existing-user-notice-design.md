# Existing-user (pre-server-migration) notice: copy + sequencing fix

## Problem

`ServerMigrationNoticeView` (see `docs/superpowers/specs/2026-08-04-pre-server-migration-notice-design.md`
for its original design) is shown once to devices that completed onboarding before Yana required a
server. Two issues:

1. The copy reads like a legal notice rather than a friendly heads-up, and its link/button labels
   are longer than necessary.
2. `ContentView.onAppear` can set both `showServerMigrationNotice` and `showWelcome` (or open both
   Mac windows) in the same pass: a pre-migration user has, by definition, completed onboarding but
   never paired, so `AuthenticatedClient.current() == nil` is true almost every time — the exact
   condition that also triggers the re-pairing Welcome flow. The two full-screen covers/windows race
   instead of the notice cleanly showing first.

## Copy changes (`ServerMigrationNoticeView.swift`)

- Title: "Yana Now Runs on a Server"
- Body, same three points, warmer/tighter wording, short link labels:
  - Explanation of the server model → link **"Learn More"**
  - v1.1.0 fallback → link **"Get Yana 1.1.0"**
  - Refund offer → link **"Request a Refund"**
- Dismiss button: **"Continue"** (it leads into pairing next, not just a dismissal)

## Sequencing fix

Add `WelcomeGate.neededStep(hasCompletedOnboarding:isPaired:) -> WelcomeView.Step?`
(`Yana/Models/WelcomeGate.swift`), a pure helper extracting the existing "does this device need
Welcome, and at which step" logic.

- `ContentView.onAppear`: evaluate migration-notice eligibility first; only evaluate/present Welcome
  if the notice is not about to auto-show this launch.
- When the notice is dismissed — iOS `fullScreenCover`'s `onDismiss` closure in `ContentView`, and
  Mac's `ServerMigrationNoticeWindowRoot` — re-run `WelcomeGate.neededStep` and present
  Welcome/pairing then. `ServerMigrationNoticeWindowRoot` needs `appState` (like `WelcomeWindowRoot`
  already does) and `openWindow` to do this; `YanaApp.swift`'s `WindowGroup` for
  `WindowID.serverNotice` passes it in.

Result: existing users always see notice → (dismiss) → Welcome/pairing, never both at once.

## Scope

Touches `ServerMigrationNoticeView.swift`, `ContentView.swift`, `ServerMigrationNoticeWindowRoot.swift`,
`YanaApp.swift`, and the new `WelcomeGate.swift`. No behavior change for devices that aren't
classified as pre-server-migration users.
