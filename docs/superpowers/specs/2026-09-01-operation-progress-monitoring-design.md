# Operation progress monitoring

Date: 2026-09-01
Repos: `yana-server` (ships first), `yana-ios`

## Problem

The app reports a per-article reload as finished before the server has finished it.

`ReaderActions.forceUpdateArticle` POSTs `/api/v1/articles/:id/reload` and then calls
`UpdateAndSync.pollForReloadedContent`, which waits for a terminal `job` event on the
`/api/v1/jobs/events` SSE stream. That wait has a 10s default timeout, and the timeout is
treated as success: `waitForReloadJobOutcome` returns `nil`, `pollForReloadedContent` maps `nil`
to "fetch the content and return `true`", and `true` becomes `.applied`, which shows
«Reloaded "<feed>".» So any reload slower than 10s reports done and displays the pre-reload
content.

10s is nothing on the server side. The reload job is enqueued as `pending`; the worker claims
pending jobs on a 2s jittered poll (`src/lib/jobs/worker.ts:123-126`) and then refetches the
source page, re-extracts it, and may run AI post-processing, under a per-job budget of 300s.

The 10s came from commit `592f196` and was a workaround for a different defect: the SSE stream is
opened *after* the reload POST, so a job that finishes inside the connect window emits its one
terminal event before anyone is listening, and it is gone for good. Shortening the timeout bounded
the resulting stall; it did not make the answer true.

Two more surfaces have the same defect:

- `UpdateAndSync.pollForFreshContent` ("Update All") polls `/api/v1/runs/:id` 30 times at 1s and
  then syncs and reports `.applied(newCount:)` regardless — a multi-feed run outlasts 30s easily,
  producing a premature "No new articles."
- `UpdateActivity.waitUntilIdle` gives up after 35s, dropping the pull-to-refresh spinner while
  the work continues.

## Goals

- Never report an operation as finished until the server says it is finished.
- Show real progress (spinner plus percentage) for both a single-article reload and an Update All
  run.
- Never lose the state of an in-flight operation, including across an app relaunch: on launch the
  app re-checks what it had triggered and picks the monitoring back up.

## Non-goals

- No phase or step labels. Percentage plus spinner only.
- No monitoring of work this device did not trigger (a run started in the server's web UI or on
  another paired device). Nothing new is added to discover such work.
- No server-side cancel route. Cancelling locally means "stop watching here"; the server keeps
  working and its result lands through the next ordinary sync.
- No backwards compatibility with a server that lacks the routes below. The client requires them.

## Approach

REST is the source of truth; SSE is a latency accelerator.

The client persists what it triggered and polls the durable job/run row until that row reports a
terminal status. The SSE stream, when it is connected, delivers the same percentages sooner and can
short-circuit a sleep, but it never decides an outcome by itself. This matches the server's own
documented posture — `src/lib/api/events.ts` calls the stream best-effort and the `jobs`/`runs`
tables the source of truth — and it makes a resumed operation take the exact same code path as a
fresh one, so restart recovery is not a second mechanism.

The rejected alternative was to make SSE authoritative with reconnect plus reconcile-on-connect.
It needs reconnect/backoff machinery, and because an intermediary can silently swallow an event
stream it still needs a watchdog poll, which is this approach with extra parts.

## Server changes (`yana-server`)

Everything the client needs is already persisted. `jobs` carries `status`, `progress` (0-100),
`error`, `startedAt`, `finishedAt`; `runs` carries `status` and the `totalJobs`/`completedJobs`/
`failedJobs` counters. What is missing is `/api/v1` exposure, progress events for non-terminal
transitions, and any progress reporting at all from the reload handler.

### `GET /api/v1/jobs/:id` (new)

Bearer-authenticated, user-scoped exactly the way `/api/v1/runs/:id` is: a row owned by another
user, a row with no owner (`jobs.userId IS NULL`, e.g. the `retention` kind), and a nonexistent id
all answer the same 404 as each other, so the route cannot enumerate other users' job ids.

```json
{
  "jobId": 42,
  "runId": null,
  "kind": "article.reload",
  "progress": 55,
  "status": "running",
  "error": "",
  "startedAt": "2026-09-01T10:00:00.000Z",
  "finishedAt": null
}
```

`progress` is the progress signal. `status` is one of `pending`, `running`, `cancelling`,
`completed`, `failed`, `cancelled`; the client reads it only to decide that the work has ended and
whether it succeeded.

### `GET /api/v1/runs/:id` gains `progress`

The run's percentage is computed server-side — `round((completedJobs + failedJobs) / totalJobs *
100)`, and `100` when `totalJobs` is 0 — rather than leaving each client to derive it. The
existing `status` and counter fields stay: the web UI reads them.

### Progress events over SSE

`queue.progress()` publishes a `job` event carrying the new percentage whenever the stored value
actually changes. Its existing read-before-write dedupe (`src/lib/jobs/queue.ts:201-222`) is the
throttle: an aggregate job over 200 articles moves through about twenty distinct values, so this
is ~20 events, not 200. Publishing needs the row's `userId`/`kind`/`runId`, so the existing
`SELECT progress` widens to include them.

`publishJobOutcome` sends the real percentage for a `failed`/`cancelled` job instead of the last
written value, and the `run` event gains the same `progress` field the REST route now returns.

### Reload progress

`handleReloadJob` never calls `progress()` today, unlike `handleAggregateJob`, so a reload has no
percentage to report. It gains calls at its existing phase boundaries: claimed (5), source
refetched (30), content extracted (55), AI options applied (80), blocks written (100).

### Server tests

- `/api/v1/jobs/:id`: own job returns the shape above; another user's job, an unowned job, and a
  nonexistent id each 404.
- `/api/v1/runs/:id`: `progress` matches the counters, including the `totalJobs === 0` case.
- `queue.progress()` publishes a `job` event with the new percentage, and publishes nothing when
  the value is unchanged.
- `handleReloadJob` reports progress and reaches 100 on success.

## Client changes (`yana-ios`)

### `TrackedOperation` and its persistence

```swift
struct TrackedOperation: Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case reloadArticle(serverID: Int)
        case updateAll
    }
    let kind: Kind
    let id: Int          // jobId for .reloadArticle, runId for .updateAll
    let startedAt: Date
}
```

Persisted as `AppSettings.trackedOperations: [TrackedOperation]`, JSON in `UserDefaults`, the same
pattern `pendingWrites` and `pendingReadingPositionPush` already use. A record is written the
moment the triggering POST acks with an id, and removed only when a terminal status has been
observed and its follow-up work has been applied.

### `OperationMonitor`

New `@MainActor @Observable` service (`Yana/Services/OperationMonitor.swift`) that owns everything
after the trigger:

- `track(_ operation: TrackedOperation)` persists the record and starts monitoring it.
- `resume()` reads the persisted records and monitors them. Called from `YanaApp`'s scene `.task`
  at launch and on `scenePhase` returning to `.active`. A fresh and a resumed operation run the
  identical loop; there is no separate recovery path.
- One SSE subscription for the whole monitor, opened before any POST so a fast job's event cannot
  land in a connect gap. Events update the published percentage and can end a poll sleep early.
- Per operation, a poll loop against `/api/v1/jobs/:id` (`.reloadArticle`) or `/api/v1/runs/:id`
  (`.updateAll`) at 2s for the first minute and 5s after that, publishing each response's
  `progress`.
- The loop ends only on a terminal `status`. On success: `.reloadArticle` runs the existing
  content-apply path (fetch `/articles/:id/content`, apply through `SyncWriter` and to the visible
  `Article`, then one `SyncEngine.sync()` for the possibly-rewritten title); `.updateAll` runs one
  `SyncEngine.sync()`. On `failed`/`cancelled`, no fetch. Either way the record is then cleared and
  the outcome published.
- A 404 means the row was pruned out from under the poll: apply the content anyway (the fetch is
  cheap and idempotent) but publish the outcome as unconfirmed rather than as a success.
- No timeout is ever treated as success. A transport failure retries, and leaves the record in
  place so a relaunch resumes it. The natural bound is the server's own 300s per-job budget, after
  which the row reaches a terminal status on its own.

Published state: `progressPercent: Int?` — 0-100 exactly as the wire carries it, no unit
conversion, `nil` when nothing is active. With more than one operation in flight it is the
percentage of the most recently updated one. Plus `isActive: Bool` and `lastOutcome`.

### Outcome reporting moves to the monitor

The view that triggered the work — or the whole process — can be gone when the truth arrives, so
the monitor publishes `lastOutcome` and `ReaderHostView`/`TimelineModel` observe it to show the
toast and bump `reloadToken`. `ReaderActions.forceUpdateArticle` and
`ReaderActions.triggerRefresh` stop returning an applied/failed verdict; they POST and hand the id
to the monitor.

`UpdateAndSync.pollForFreshContent` and `pollForReloadedContent` are removed. Its
`fetchAndApplyContent` logic survives as the monitor's terminal-success path, including the two
behaviours their doc comments pin: the write to the caller's visible `Article` object (a sibling
context's save does not refresh an already-registered object) and `Block.preservingSummary` on both
write paths.

### UI

`UpdateActivity` stays the "is anything running" source but is driven by the monitor and gains
`progressPercent: Int?`, mirroring the monitor's published value. Its `waitUntilIdle` 35s cap is
removed.

The three existing spinner surfaces show the percentage next to the spinner:
`ReaderArticleViewController`'s toolbar indicator item, `MacRootView`'s chrome spinner, and
`ArticleListView`'s toolbar item. `ArticleListView`'s stop button now means "stop watching on this
device" — it drops the tracked record; the server keeps working and the result lands via the next
sync.

Pull-to-refresh's `UIRefreshControl` ends as soon as the trigger is accepted rather than waiting
for completion. It cannot spin for minutes, and it is honest now that no "done" toast fires at
that moment; the toolbar spinner and percentage carry the real state.

New user-facing strings, both with German translations: a percentage format for the spinner label,
and one message for an outcome that could not be confirmed.

### Client tests

New `OperationMonitorTests`:

- stays active while the polled status is `pending` and then `running`, publishing each percentage;
- on a terminal `completed`, applies the content and clears the persisted record;
- on `failed`, clears the record and fetches nothing;
- `resume()` monitors a record persisted in a previous session with no trigger in this one;
- an SSE terminal event short-circuits the poll sleep;
- percentage is published from both the job route and the run route;
- a 404 mid-poll applies content but reports the outcome as unconfirmed.

`UpdateAndSyncTests` is rewritten against the monitor, keeping its two regression cases: the
visible-`Article` direct update and the title picked up by the follow-up sync.

## Rollout

Two changes in two repos. The server ships first, because the client now requires
`GET /api/v1/jobs/:id` and `progress` on the run route, and no compatibility fallback is provided.
