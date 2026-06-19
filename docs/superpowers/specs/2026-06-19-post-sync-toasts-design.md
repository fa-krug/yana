# Replace post-sync dialogs with toasts

**Date:** 2026-06-19
**Status:** Approved (pending spec review)

## Goal

Replace every dialog/alert that appears as the result of a sync/update operation with the
app's existing transient "toast" (the auto-dismissing capsule overlay). After this change no
sync result or sync-adjacent error is surfaced as a modal alert — only true confirmations
(delete feed/article/tag) remain as dialogs.

## Background

The app already has a toast pattern, but it is inlined in `ReaderScreen`
(`Yana/Reader/ReaderHostView.swift`): a `@State statusMessage: String?`, a top `.overlay`
rendering a `.thinMaterial` capsule, and a `.task(id:)` that clears it after 2.5s. It has no
style variants and is not reusable.

Dialogs currently shown after sync / sync-adjacent operations:

1. **Reader "Update Failed" alert** (`ReaderHostView.swift` ~170–178) — shown on sync failure
   via `appState.errorMessage`; has **Retry** + OK buttons. Set at lines 293 and 308.
2. **Reader "Summarize Failed" alert** (`ReaderHostView.swift` ~165–169) — shown when AI
   summarize fails; `@State summarizeFailed`, set at line 243.
3. **FeedsView "Feeds" alert** (`FeedsView.swift` ~124–128) — `@State importMessage`, used for:
   - `updateAll()` result (line 210)
   - `updateOne(feed:)` result (line 218)
   - `forceReloadOne(feed:)` result (line 226)
   - OPML export failure (line 238)
   - OPML import file-read error (line 247)
   - OPML import result (line 251)

`appState.errorMessage` is used **only** by dialog (1) — confirmed via grep — so it becomes
dead once that alert is removed.

## Decisions

- **Scope:** Convert dialogs (1), (2), and (3) — all FeedsView alerts (sync results *and* OPML
  import/export messages) plus both Reader error alerts. Delete confirmation dialogs stay as
  dialogs.
- **Failures:** Failure messages become error-styled toasts (distinct tint), auto-dismissing
  with no Retry button. The one-tap Retry affordance is intentionally dropped; the user can
  pull to refresh again.

## Design

### 1. New reusable toast component — `Yana/Views/Toast.swift`

```swift
enum ToastStyle { case info, error }

struct ToastMessage: Equatable {
    var text: String
    var style: ToastStyle = .info
}

extension View {
    func toast(_ message: Binding<ToastMessage?>) -> some View { ... }
}
```

- `.info` reproduces the current look: `.thinMaterial` background in a `Capsule`, primary text.
- `.error` uses a warning tint (red capsule, white text) to distinguish failures.
- The modifier renders a top-aligned overlay, transitions `.move(edge: .top)` + `.opacity`,
  auto-dismisses after 2.5s via `.task(id:)`, and animates with `.snappy` — i.e. the exact
  behavior currently inlined in `ReaderScreen`, now factored out and style-aware.
- Lives in `Yana/Views/` alongside other top-level shared components (`TagChip.swift`).

### 2. `ReaderScreen` (`Yana/Reader/ReaderHostView.swift`)

- Replace `@State statusMessage: String?` with `@State toast: ToastMessage?`.
- Replace the inline `.overlay`/`.animation` with `.toast($toast)`.
- Remove the `.alert("Update Failed", …)` block (and Retry).
- Remove the `.alert("Summarize Failed", …)` block and the `@State summarizeFailed` flag.
- Call-site updates:
  - Fullscreen hint, filter-clamp message, refresh success, force-update success →
    `ToastMessage(text:, style: .info)`.
  - Sync failure (lines 293/308) → `ToastMessage(text: failure, style: .error)`.
  - Summarize failure (line 243) →
    `ToastMessage(text: "Could not summarize this article. Please try again.", style: .error)`.
- Remove `var errorMessage: String?` from `AppState` (`Yana/Models/AppState.swift`) — now unused.

After this, `ReaderScreen` presents no `.alert`.

### 3. `FeedsView.swift`

- Replace `@State importMessage: String?` with `@State toast: ToastMessage?`.
- Replace the `.alert("Feeds", …)` block with `.toast($toast)`.
- Call-site updates:
  - `updateAll` / `updateOne` / `forceReloadOne` results and OPML import result → `.info`.
  - OPML export failure and file-read error → `.error`.
- Keep the delete `.confirmationDialog` unchanged.

## Strings / translations

No new user-facing strings. All toast messages reuse the existing localized strings verbatim
(`RefreshOutcome`, `SyncFailureSummary`, the summarize/import/export literals already in
`Localizable.xcstrings`). No catalog changes required.

## Testing

- `RefreshOutcome` and `SyncFailureSummary` message-building logic is untouched and retains its
  existing coverage.
- The toast is presentation-only. `ToastMessage` is `Equatable`; a small sanity test is optional.
- Primary verification: the project builds via
  `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`.

## Out of scope

- Delete confirmation dialogs (feed/article/tag) remain dialogs.
- The "Notifications Disabled" settings alert is not sync-related and is left unchanged.
