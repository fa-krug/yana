# Replace Post-Sync Dialogs With Toasts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every post-sync dialog/alert (Reader "Update Failed" + "Summarize Failed", FeedsView "Feeds" alert) with the app's transient toast overlay, factored into a reusable style-aware component.

**Architecture:** Extract the inline `statusMessage` capsule overlay from `ReaderScreen` into a reusable `Yana/Views/Toast.swift` (`ToastStyle` info/error, `ToastMessage`, `.toast($binding)` view modifier). Migrate `ReaderScreen` and `FeedsView` to drive that modifier with `ToastMessage` values instead of `.alert`. Delete confirmation dialogs are untouched.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XcodeGen, Swift Testing.

## Global Constraints

- iOS 26.0+; Swift 6 strict concurrency; `@MainActor` throughout.
- New source files under `Yana/` are auto-included by XcodeGen path glob — run `xcodegen generate` after adding a file before building.
- Build/test command: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build` (swap `build`→`test` to run tests).
- No new user-facing strings are introduced; all toast text reuses existing localized strings, so `Localizable.xcstrings` is NOT modified.
- Tests use Swift Testing (`import Testing`), `@MainActor`.

---

### Task 1: Reusable Toast component

**Files:**
- Create: `Yana/Views/Toast.swift`
- Test: `YanaTests/ToastMessageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ToastStyle { case info, error }`
  - `struct ToastMessage: Equatable { var text: String; var style: ToastStyle = .info }`
  - `extension View { func toast(_ message: Binding<ToastMessage?>) -> some View }`

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ToastMessageTests.swift`:

```swift
import Testing
@testable import Yana

@MainActor
struct ToastMessageTests {
    @Test func defaultStyleIsInfo() {
        let msg = ToastMessage(text: "Hello")
        #expect(msg.style == .info)
        #expect(msg.text == "Hello")
    }

    @Test func errorStyleIsPreserved() {
        let msg = ToastMessage(text: "Boom", style: .error)
        #expect(msg.style == .error)
    }

    @Test func equatableComparesTextAndStyle() {
        #expect(ToastMessage(text: "a") == ToastMessage(text: "a"))
        #expect(ToastMessage(text: "a") != ToastMessage(text: "a", style: .error))
        #expect(ToastMessage(text: "a") != ToastMessage(text: "b"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: FAIL — `cannot find 'ToastMessage' in scope` / `cannot find type 'ToastStyle'`.

- [ ] **Step 3: Create the Toast component**

Create `Yana/Views/Toast.swift`:

```swift
import SwiftUI

/// Visual variant for a transient toast: neutral info vs. a tinted error.
enum ToastStyle {
    case info
    case error
}

/// A transient status message shown as an auto-dismissing capsule at the top of the screen.
struct ToastMessage: Equatable {
    var text: String
    var style: ToastStyle = .info
}

private struct ToastModifier: ViewModifier {
    @Binding var message: ToastMessage?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(message.style == .error ? Color.white : Color.primary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(background(for: message.style), in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(2.5))
                            self.message = nil
                        }
                }
            }
            .animation(.snappy, value: message)
    }

    @ViewBuilder
    private func background(for style: ToastStyle) -> some View {
        switch style {
        case .info: Capsule().fill(.thinMaterial)
        case .error: Capsule().fill(Color.red)
        }
    }
}

extension View {
    /// Presents `message` as a transient toast that auto-dismisses after 2.5s and clears the binding.
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
```

- [ ] **Step 4: Regenerate the project and run the test**

Run: `xcodegen generate`
Then: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS for `ToastMessageTests`; project builds.

- [ ] **Step 5: Commit**

```bash
git add Yana/Views/Toast.swift YanaTests/ToastMessageTests.swift
git commit -m "feat(ui): reusable style-aware toast component"
```

(`Yana.xcodeproj` is gitignored and regenerated by `xcodegen generate`; do not add it.)

---

### Task 2: Migrate ReaderScreen to toasts; drop AppState.errorMessage

**Files:**
- Modify: `Yana/Reader/ReaderHostView.swift`
- Modify: `Yana/Models/AppState.swift:9`

**Interfaces:**
- Consumes: `ToastMessage`, `ToastStyle`, `.toast(_:)` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Remove `errorMessage` from AppState**

In `Yana/Models/AppState.swift`, delete the line:

```swift
    var errorMessage: String?
```

- [ ] **Step 2: Replace state declarations in `ReaderScreen`**

In `Yana/Reader/ReaderHostView.swift`, replace:

```swift
    @State private var statusMessage: String?
```
with:
```swift
    @State private var toast: ToastMessage?
```

and delete:

```swift
    @State private var summarizeFailed = false
```

- [ ] **Step 3: Remove both alerts and the inline overlay; add the toast modifier**

In `ReaderScreen.body`, delete this block (the two alerts + the inline overlay + animation):

```swift
        .alert("Summarize Failed", isPresented: $summarizeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Could not summarize this article. Please try again.")
        }
        .alert("Update Failed", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("Retry") { triggerRefresh() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: statusMessage) {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.statusMessage = nil
                    }
            }
        }
        .animation(.snappy, value: statusMessage)
```

and replace it with:

```swift
        .toast($toast)
```

- [ ] **Step 4: Update the fullscreen-hint call site**

In `.onAppear`, replace:

```swift
                statusMessage = String(localized: "Tap the title bar to hide the toolbars.")
```
with:
```swift
                toast = ToastMessage(text: String(localized: "Tap the title bar to hide the toolbars."))
```

- [ ] **Step 5: Update the filter-clamp call site**

In `clampIndex()`, replace:

```swift
            statusMessage = String(localized: "Showing the nearest article in this filter.")
```
with:
```swift
            toast = ToastMessage(text: String(localized: "Showing the nearest article in this filter."))
```

- [ ] **Step 6: Update the summarize-failure call site**

In `summarize(_:)`, replace:

```swift
            } else {
                summarizeFailed = true
            }
```
with:
```swift
            } else {
                toast = ToastMessage(
                    text: String(localized: "Could not summarize this article. Please try again."),
                    style: .error
                )
            }
```

- [ ] **Step 7: Update `forceUpdateArticle(_:)` success + failure call sites**

Replace:

```swift
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                appState.errorMessage = failure
            } else {
                statusMessage = RefreshOutcome.message(newCount: count, feedName: feedName)
                Haptics.impact(.light)
            }
```
with:
```swift
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                toast = ToastMessage(text: failure, style: .error)
            } else {
                toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feedName))
                Haptics.impact(.light)
            }
```

- [ ] **Step 8: Update `triggerRefresh()` success + failure call sites**

Replace:

```swift
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                appState.errorMessage = failure
            } else {
                statusMessage = RefreshOutcome.message(newCount: count, feedName: nil)
                Haptics.impact(.light)
            }
```
with:
```swift
            if let failure = SyncFailureSummary.message(for: service.lastRunFailures) {
                toast = ToastMessage(text: failure, style: .error)
            } else {
                toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: nil))
                Haptics.impact(.light)
            }
```

- [ ] **Step 9: Build to verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED, no references to `statusMessage`, `summarizeFailed`, or `errorMessage` remain. Confirm with: `grep -rn "statusMessage\|summarizeFailed\|errorMessage" Yana/` → no output.

- [ ] **Step 10: Commit**

```bash
git add Yana/Reader/ReaderHostView.swift Yana/Models/AppState.swift
git commit -m "feat(reader): show sync/summarize results as toasts, not alerts"
```

---

### Task 3: Migrate FeedsView to toasts

**Files:**
- Modify: `Yana/Views/Config/FeedsView.swift`

**Interfaces:**
- Consumes: `ToastMessage`, `ToastStyle`, `.toast(_:)` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Replace the state declaration**

In `Yana/Views/Config/FeedsView.swift`, replace:

```swift
    @State private var importMessage: String?
```
with:
```swift
    @State private var toast: ToastMessage?
```

- [ ] **Step 2: Replace the alert with the toast modifier**

Delete:

```swift
        .alert("Feeds", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
```

and replace it with:

```swift
        .toast($toast)
```

(Leave the `.confirmationDialog` for delete untouched.)

- [ ] **Step 3: Update the three sync result call sites**

In `updateAll()` replace:
```swift
            importMessage = RefreshOutcome.message(newCount: count, feedName: nil)
```
with:
```swift
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: nil))
```

In `updateOne(_:)` replace:
```swift
            importMessage = RefreshOutcome.message(newCount: count, feedName: feed.name)
```
with:
```swift
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feed.name))
```

In `forceReloadOne(_:)` replace:
```swift
            importMessage = RefreshOutcome.message(newCount: count, feedName: feed.name)
```
with:
```swift
            toast = ToastMessage(text: RefreshOutcome.message(newCount: count, feedName: feed.name))
```

- [ ] **Step 4: Update the OPML export/import call sites**

In `exportOPML()` replace:
```swift
            importMessage = String(localized: "Export failed.")
```
with:
```swift
            toast = ToastMessage(text: String(localized: "Export failed."), style: .error)
```

In `handleImport(_:)` replace:
```swift
            importMessage = String(localized: "Could not read the file.")
```
with:
```swift
            toast = ToastMessage(text: String(localized: "Could not read the file."), style: .error)
```

and replace:
```swift
        importMessage = String(localized: "Imported \(r.imported) feeds, skipped \(r.skipped).")
```
with:
```swift
        toast = ToastMessage(text: String(localized: "Imported \(r.imported) feeds, skipped \(r.skipped)."))
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. Confirm no leftover references: `grep -rn "importMessage" Yana/` → no output.

- [ ] **Step 6: Commit**

```bash
git add Yana/Views/Config/FeedsView.swift
git commit -m "feat(feeds): show update/reload/OPML results as toasts, not an alert"
```

---

## Notes for the implementer

- The `Color.red` error background is a deliberate, simple choice matching the spec's "distinct tint". Do not add new assets or colors.
- Do NOT touch: delete confirmation dialogs (feed/article/tag), the Settings "Notifications Disabled" alert (not sync-related).
- `RefreshOutcome.message(...)` and `SyncFailureSummary.message(for:)` are existing, unchanged helpers — call them exactly as shown.
