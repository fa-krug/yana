# Operation Progress Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app report a reload or an Update All as finished only when the server actually finished it, showing a real percentage while it works and resuming monitoring after an app relaunch.

**Architecture:** The durable `jobs`/`runs` rows are the source of truth. The server exposes them on `/api/v1` and publishes percentage changes over its existing SSE stream. The client persists what it triggered, polls the row until its status is terminal, and treats SSE only as a way to get the same numbers sooner. No timeout ever counts as success.

**Tech Stack:** `yana-server` — Next.js App Router route handlers, Drizzle/SQLite, Vitest, Zod-based API doc registry. `yana-ios` — Swift 6 / SwiftUI / SwiftData, Swift Testing (`import Testing`), `MockURLProtocol` for network stubs.

**Spec:** `docs/superpowers/specs/2026-09-01-operation-progress-monitoring-design.md`

## Global Constraints

- Two repos. `yana-server` lives at `/Users/skrug/PycharmProjects/yana-server`, `yana-ios` at the current worktree. Tasks 1-4 are server; tasks 5-13 are client. **Server tasks must all land and be pushed before the client tasks are useful** — there is no compatibility fallback by design.
- Percentage is the progress signal: `progress` is an integer 0-100 on every wire shape, carried verbatim to the UI with no unit conversion. `status` is read only to decide the work has ended and whether it succeeded.
- No phase or step labels anywhere. Spinner plus percentage only.
- No server-side cancel route. Cancelling locally means "stop watching on this device".
- Every user-facing string added to `Yana/Resources/Localizable.xcstrings` MUST have a `de` translation marked `"state" : "translated"`. German follows Apple style (infinitive for actions, no "Du"/"Sie").
- User-facing copy must read as natural prose: no bullet points, no em/en dashes as a rhetorical device.
- Swift: strict concurrency, `@MainActor` on UI/service types, every `@ModelActor` call from a `@MainActor` context wrapped in `OffMainActor.run`.
- Server tests: `npx vitest run <path>` from `/Users/skrug/PycharmProjects/yana-server`.
- Client tests: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test` from the worktree root. Never run two `xcodebuild test` invocations concurrently.

---

## Part A — Server (`yana-server`)

All Part A commands run from `/Users/skrug/PycharmProjects/yana-server`.

### Task 1: Run progress percentage

**Files:**
- Modify: `src/app/api/v1/runs/[id]/route.ts:44-50`
- Modify: `src/lib/api/docs/schemas.ts:53-59` (`RunSchema`)
- Modify: `src/lib/jobs/queue.ts:474-487` (the `run` event inside `publishJobOutcome`)
- Modify: `src/lib/api/docs/schemas.ts:166-172` (the run variant of `ApiEventPayloadSchema`)
- Test: `src/app/api/v1/runs/[id]/route.test.ts`

**Interfaces:**
- Produces: `runProgressPercent(totalJobs: number, completedJobs: number, failedJobs: number): number` exported from `src/lib/jobs/queue.ts`, used by Task 1's route and by the `run` event payload.

- [ ] **Step 1: Write the failing tests**

Append to `src/app/api/v1/runs/[id]/route.test.ts`, inside the existing `describe`:

```ts
  it("reports 0 progress for a run whose jobs have not finished", async () => {
    const owner = await createUserWithPassword({
      email: "o-progress@example.com",
      password: "correct horse battery staple",
    });
    const { token } = await createDeviceSession(owner.id, "Test");
    const { enqueueRun } = await import("@/lib/jobs/queue");
    const runId = enqueueRun(owner.id, "aggregate", [{ feedId: 1 }, { feedId: 2 }]);

    const response = await GET(
      new Request(`https://example.com/api/v1/runs/${runId}`, {
        headers: { authorization: `Bearer ${token}` },
      }),
      { params: Promise.resolve({ id: String(runId) }) },
    );
    const body = await response.json();
    expect(body.progress).toBe(0);
  });

  it("reports the percentage of finished jobs, counting failures", async () => {
    const owner = await createUserWithPassword({
      email: "o-progress2@example.com",
      password: "correct horse battery staple",
    });
    const { token } = await createDeviceSession(owner.id, "Test");
    const { enqueueRun, claim, complete, fail } = await import("@/lib/jobs/queue");
    const runId = enqueueRun(owner.id, "aggregate", [
      { feedId: 1 },
      { feedId: 2 },
      { feedId: 3 },
      { feedId: 4 },
    ]);

    const first = claim();
    complete(first!.id);
    const second = claim();
    fail(second!.id, "boom");

    const response = await GET(
      new Request(`https://example.com/api/v1/runs/${runId}`, {
        headers: { authorization: `Bearer ${token}` },
      }),
      { params: Promise.resolve({ id: String(runId) }) },
    );
    const body = await response.json();
    expect(body.progress).toBe(50);
    expect(body.completedJobs).toBe(1);
    expect(body.failedJobs).toBe(1);
  });
```

Add to `src/lib/jobs/queue.test.ts`:

```ts
  it("runProgressPercent reports 100 for a run with no jobs", async () => {
    const { runProgressPercent } = await import("./queue");
    expect(runProgressPercent(0, 0, 0)).toBe(100);
  });

  it("runProgressPercent rounds to the nearest whole percent", async () => {
    const { runProgressPercent } = await import("./queue");
    expect(runProgressPercent(3, 1, 0)).toBe(33);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run src/app/api/v1/runs/\[id\]/route.test.ts src/lib/jobs/queue.test.ts`
Expected: FAIL — `body.progress` is `undefined`, and `runProgressPercent` is not exported.

- [ ] **Step 3: Add the helper**

In `src/lib/jobs/queue.ts`, next to `getRun`:

```ts
/**
 * A run's completion as a whole percent. Computed here, once, rather than in
 * each client: `GET /api/v1/runs/:id` and the `run` SSE event must agree, and
 * the native client drives its progress display straight off this number.
 * A run with no jobs is 100, not 0 -- there is nothing left to wait for.
 */
export function runProgressPercent(
  totalJobs: number,
  completedJobs: number,
  failedJobs: number,
): number {
  if (totalJobs <= 0) return 100;
  return Math.round(((completedJobs + failedJobs) / totalJobs) * 100);
}
```

- [ ] **Step 4: Return it from the route**

In `src/app/api/v1/runs/[id]/route.ts`, import `runProgressPercent` from `@/lib/jobs/queue` and extend the response:

```ts
    return Response.json({
      runId: run.id,
      status: run.status,
      progress: runProgressPercent(run.totalJobs, run.completedJobs, run.failedJobs),
      totalJobs: run.totalJobs,
      completedJobs: run.completedJobs,
      failedJobs: run.failedJobs,
    });
```

- [ ] **Step 5: Add it to the `run` SSE event**

In `src/lib/jobs/queue.ts`, inside `publishJobOutcome`'s run branch:

```ts
        publishUserEvent(userId, {
          type: "run",
          payload: {
            runId: run.id,
            status: run.status,
            progress: runProgressPercent(run.totalJobs, run.completedJobs, run.failedJobs),
            totalJobs: run.totalJobs,
            completedJobs: run.completedJobs,
            failedJobs: run.failedJobs,
          },
        });
```

In `src/lib/api/events.ts`, add `progress: number;` to the `run` variant's payload type.

- [ ] **Step 6: Update the API documentation schemas**

In `src/lib/api/docs/schemas.ts`, add `progress: z.number().int(),` to `RunSchema` (after `status`) and to the run variant of `ApiEventPayloadSchema` (after `status`).

- [ ] **Step 7: Run the tests to verify they pass**

Run: `npx vitest run src/app/api/v1/runs/\[id\]/route.test.ts src/lib/jobs/queue.test.ts src/lib/api/docs`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/app/api/v1/runs src/lib/jobs/queue.ts src/lib/jobs/queue.test.ts src/lib/api/events.ts src/lib/api/docs/schemas.ts
git commit -m "Report a run's completion as a percentage on both the REST route and the SSE event"
```

---

### Task 2: `GET /api/v1/jobs/:id`

**Files:**
- Create: `src/app/api/v1/jobs/[id]/route.ts`
- Create: `src/app/api/v1/jobs/[id]/route.test.ts`
- Modify: `src/lib/api/docs/schemas.ts` (add `JobSchema`)
- Modify: `src/lib/api/docs/registry.ts:195-213` (add the endpoint next to the Runs entry)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `GET /api/v1/jobs/:id` returning `{ jobId, runId, kind, progress, status, error, startedAt, finishedAt }`. `startedAt`/`finishedAt` are ISO 8601 strings or `null`. The client (Task 5) decodes them as strings, never as `Date`.

- [ ] **Step 1: Write the failing test**

Create `src/app/api/v1/jobs/[id]/route.test.ts`:

```ts
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { applyMigrationsAt } from "@/lib/db/test-support";

vi.mock("next/server", () => import("@/test/next-server"));

describe("GET /api/v1/jobs/[id]", () => {
  let dbPath: string;
  let GET: typeof import("./route").GET;
  let createUserWithPassword: typeof import("@/lib/auth/server").createUserWithPassword;
  let createDeviceSession: typeof import("@/lib/auth/server").createDeviceSession;

  beforeEach(async () => {
    vi.resetModules();
    const stamp = `${process.pid}-${Math.random().toString(36).slice(2)}`;
    dbPath = path.join(os.tmpdir(), `yana-jobs-route-${stamp}.db`);
    applyMigrationsAt(dbPath);
    process.env.DATABASE_PATH = dbPath;
    process.env.BETTER_AUTH_SECRET = "test-secret-not-used-outside-this-file-0123456789";

    ({ createUserWithPassword, createDeviceSession } = await import("@/lib/auth/server"));
    ({ GET } = await import("./route"));
  });

  afterEach(() => fs.rmSync(dbPath, { force: true }));

  const call = (id: string, token?: string) =>
    GET(
      new Request(`https://example.com/api/v1/jobs/${id}`, {
        headers: token ? { authorization: `Bearer ${token}` } : {},
      }),
      { params: Promise.resolve({ id }) },
    );

  it("401s with no Authorization header", async () => {
    const response = await call("1");
    expect(response.status).toBe(401);
    expect((await response.json()).error.code).toBe("unauthorized");
  });

  it("returns the job's durable state for its owner", async () => {
    const owner = await createUserWithPassword({
      email: "j-owner@example.com",
      password: "correct horse battery staple",
    });
    const { token } = await createDeviceSession(owner.id, "Test");
    const { enqueue, progress } = await import("@/lib/jobs/queue");
    const jobId = enqueue("article.reload", { articleId: 7 }, { userId: owner.id });
    progress(jobId, 55);

    const response = await call(String(jobId), token);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      jobId,
      runId: null,
      kind: "article.reload",
      progress: 55,
      status: "pending",
      error: "",
      startedAt: null,
      finishedAt: null,
    });
  });

  it("404s for another user's job", async () => {
    const owner = await createUserWithPassword({
      email: "j-a@example.com",
      password: "correct horse battery staple",
    });
    const other = await createUserWithPassword({
      email: "j-b@example.com",
      password: "correct horse battery staple",
    });
    const { token } = await createDeviceSession(other.id, "Test");
    const { enqueue } = await import("@/lib/jobs/queue");
    const jobId = enqueue("article.reload", { articleId: 7 }, { userId: owner.id });

    const response = await call(String(jobId), token);
    expect(response.status).toBe(404);
    expect((await response.json()).error.code).toBe("not_found");
  });

  it("404s for an unowned job", async () => {
    const owner = await createUserWithPassword({
      email: "j-c@example.com",
      password: "correct horse battery staple",
    });
    const { token } = await createDeviceSession(owner.id, "Test");
    const { enqueue } = await import("@/lib/jobs/queue");
    const jobId = enqueue("retention", {});

    const response = await call(String(jobId), token);
    expect(response.status).toBe(404);
  });

  it("404s for a nonexistent and for a non-numeric id", async () => {
    const owner = await createUserWithPassword({
      email: "j-d@example.com",
      password: "correct horse battery staple",
    });
    const { token } = await createDeviceSession(owner.id, "Test");

    expect((await call("999999", token)).status).toBe(404);
    expect((await call("not-a-number", token)).status).toBe(404);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/app/api/v1/jobs/\[id\]/route.test.ts`
Expected: FAIL — cannot resolve `./route`.

- [ ] **Step 3: Write the route**

Create `src/app/api/v1/jobs/[id]/route.ts`:

```ts
import { and, eq } from "drizzle-orm";
import { connection } from "next/server";

import { ApiError, apiErrorResponse, requireApiUser } from "@/lib/api/auth";
import { getDb } from "@/lib/db/client";
import { jobs } from "@/lib/db/schema";

/**
 * The native client's poll target for one job's durable state. A standalone
 * `article.reload` job has `runId: null`, so `GET /api/v1/runs/[id]` can never
 * see it, and its single terminal SSE event is unrecoverable once missed --
 * this row is the only thing a client can ask again later, which is what makes
 * "resume monitoring after an app relaunch" possible at all.
 *
 * `progress` is the progress signal (0-100); `status` says only whether the
 * work has ended and whether it succeeded.
 *
 * Ownership is a direct `jobs.userId` check, which also excludes the unowned
 * rows (`retention` runs for every user and has no single owner), and a
 * mismatch answers the same 404 as a nonexistent id -- the same convention
 * `runs/[id]/route.ts` follows, so this route cannot enumerate other users'
 * job ids.
 *
 * `await connection()` must be the literal first statement, ahead of
 * `requireApiUser()` -- see the `connection()` bullet in the root CLAUDE.md.
 */
export async function GET(
  request: Request,
  ctx: { params: Promise<{ id: string }> },
): Promise<Response> {
  await connection();

  try {
    const user = await requireApiUser(request);

    const { id } = await ctx.params;
    const jobId = Number(id);
    if (!Number.isInteger(jobId)) throw new ApiError(404, "not_found");

    const job = getDb()
      .select()
      .from(jobs)
      .where(and(eq(jobs.id, jobId), eq(jobs.userId, user.id)))
      .get();
    if (!job) throw new ApiError(404, "not_found");

    return Response.json({
      jobId: job.id,
      runId: job.runId,
      kind: job.kind,
      progress: job.progress,
      status: job.status,
      error: job.error,
      startedAt: job.startedAt?.toISOString() ?? null,
      finishedAt: job.finishedAt?.toISOString() ?? null,
    });
  } catch (error) {
    if (error instanceof ApiError) return apiErrorResponse(error);
    throw error;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run src/app/api/v1/jobs/\[id\]/route.test.ts`
Expected: PASS

- [ ] **Step 5: Document the endpoint**

In `src/lib/api/docs/schemas.ts`, after `RunSchema`:

```ts
export const JobSchema = z.object({
  jobId: z.number().int(),
  runId: z.number().int().nullable(),
  kind: z.string(),
  progress: z.number().int(),
  status: z.enum(["pending", "running", "cancelling", "completed", "failed", "cancelled"]),
  error: z.string(),
  startedAt: z.iso.datetime().nullable(),
  finishedAt: z.iso.datetime().nullable(),
});
```

In `src/lib/api/docs/registry.ts`, import `JobSchema` alongside `RunSchema` and add this entry immediately before the `/api/v1/jobs/events` entry:

```ts
  defineEndpoint({
    method: "GET",
    path: "/api/v1/jobs/{id}",
    tag: "Jobs",
    summary: "Poll one job's progress",
    description:
      "The durable state of a single job, including the `article.reload` job " +
      "`POST /api/v1/articles/{id}/reload` returns. Such a job has `runId: null` and is " +
      "invisible to `GET /api/v1/runs/{id}`. `progress` is the progress signal (0-100); " +
      "`status` says whether the work has ended and whether it succeeded. Unlike the SSE " +
      "stream this can be asked again at any time, so a client that was offline, or was " +
      "restarted, can still learn how its job ended.",
    auth: "bearer-or-cookie",
    response: { status: 200, schema: JobSchema, description: "The job's current state." },
    errors: [
      { status: 401, code: "unauthorized", when: "no valid Bearer token or session." },
      {
        status: 404,
        code: "not_found",
        when: "the job doesn't exist, or isn't owned by the caller.",
      },
    ],
  }),
```

- [ ] **Step 6: Run the doc tests**

Run: `npx vitest run src/lib/api/docs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/app/api/v1/jobs src/lib/api/docs
git commit -m "Add GET /api/v1/jobs/:id so a client can ask how a reload job ended"
```

---

### Task 3: Publish progress events, not just terminal ones

**Files:**
- Modify: `src/lib/jobs/queue.ts:201-222` (`progress`)
- Modify: `src/lib/jobs/queue.ts:461-472` (`publishJobOutcome`'s `progress` field)
- Test: `src/lib/jobs/queue.test.ts`

**Interfaces:**
- Consumes: `resolveJobUserId(job)` (already in `queue.ts:386`), `publishUserEvent` from `@/lib/api/events`.
- Produces: a `job` SSE event on every progress change, payload `{ jobId, runId, kind, status: "running", progress }`.

- [ ] **Step 1: Write the failing tests**

Add to `src/lib/jobs/queue.test.ts`:

```ts
  it("publishes a job event carrying the new percentage when progress changes", async () => {
    const { subscribeUserEvents } = await import("@/lib/api/events");
    const { createUserWithPassword } = await import("@/lib/auth/server");
    const user = await createUserWithPassword({
      email: "p-1@example.com",
      password: "correct horse battery staple",
    });
    const { enqueue, progress } = await import("./queue");
    const jobId = enqueue("aggregate", { feedId: 1 }, { userId: user.id });

    const seen: unknown[] = [];
    const unsubscribe = subscribeUserEvents(user.id, (event) => seen.push(event));
    progress(jobId, 42);
    unsubscribe();

    expect(seen).toEqual([
      {
        type: "job",
        payload: { jobId, runId: null, kind: "aggregate", status: "running", progress: 42 },
      },
    ]);
  });

  it("publishes nothing when progress is set to the value already stored", async () => {
    const { subscribeUserEvents } = await import("@/lib/api/events");
    const { createUserWithPassword } = await import("@/lib/auth/server");
    const user = await createUserWithPassword({
      email: "p-2@example.com",
      password: "correct horse battery staple",
    });
    const { enqueue, progress } = await import("./queue");
    const jobId = enqueue("aggregate", { feedId: 1 }, { userId: user.id });
    progress(jobId, 42);

    const seen: unknown[] = [];
    const unsubscribe = subscribeUserEvents(user.id, (event) => seen.push(event));
    progress(jobId, 42);
    unsubscribe();

    expect(seen).toEqual([]);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run src/lib/jobs/queue.test.ts`
Expected: FAIL — no events are published by `progress()`.

- [ ] **Step 3: Publish from `progress()`**

Replace the body of `progress` in `src/lib/jobs/queue.ts` with:

```ts
export function progress(id: number, percent: number): void {
  const clamped = Math.min(100, Math.max(0, Math.floor(percent)));

  // Read first, outside any write transaction: the aggregate handler calls
  // this once per article, and 80 + floor(i/total*20) only takes twenty
  // distinct values across the whole loop -- so for a 200-article feed all
  // but twenty of those calls were a BEGIN IMMEDIATE that wrote the number
  // already sitting in the column. A stale read here is harmless: the worst
  // case is one redundant write, which is exactly what happened before.
  //
  // The row's identity columns come back with it because the SSE publish
  // below needs them, and because this dedupe doubles as the publish
  // throttle: one event per distinct percentage, so a 200-article job emits
  // about twenty events rather than two hundred.
  const current = getDb()
    .select({
      progress: jobs.progress,
      runId: jobs.runId,
      kind: jobs.kind,
      payload: jobs.payload,
      userId: jobs.userId,
    })
    .from(jobs)
    .where(eq(jobs.id, id))
    .get();
  if (!current || current.progress === clamped) {
    return;
  }

  writeTransaction((db) => {
    db.update(jobs).set({ progress: clamped }).where(eq(jobs.id, id)).run();
  });

  // Best-effort, exactly like publishJobOutcome: a broken subscriber must not
  // turn a successful progress write into a failed job.
  try {
    const userId = resolveJobUserId({
      id,
      runId: current.runId,
      kind: current.kind,
      payload: current.payload,
      userId: current.userId,
    } as Job);
    if (!userId) return;
    publishUserEvent(userId, {
      type: "job",
      payload: {
        jobId: id,
        runId: current.runId,
        kind: current.kind,
        status: "running",
        progress: clamped,
      },
    });
  } catch (err) {
    console.error(`[queue] failed to publish progress for job ${id}:`, err);
  }
}
```

- [ ] **Step 4: Report the real percentage on a failed job**

In `publishJobOutcome`, replace the `progress` line:

```ts
        progress: status === "completed" ? 100 : job.progress,
```

with:

```ts
        // A completed job is 100 by definition. A failed or cancelled one
        // reports how far it actually got, so the client's last displayed
        // percentage does not jump to a number that never happened.
        progress: status === "completed" ? 100 : job.progress,
```

(The value is already correct; this step is only the comment making the rule explicit. Do not change the expression.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npx vitest run src/lib/jobs/queue.test.ts`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/lib/jobs/queue.ts src/lib/jobs/queue.test.ts
git commit -m "Publish a job event on every progress change, not only on terminal transitions"
```

---

### Task 4: Reload progress

**Files:**
- Modify: `src/lib/jobs/handlers/reload.ts:12` (import) and its phase boundaries
- Test: `src/lib/jobs/handlers/handlers.test.ts`

**Interfaces:**
- Consumes: `progress(jobId, percent)` from `../queue` (Task 3's version).

- [ ] **Step 1: Write the failing test**

Add to `src/lib/jobs/handlers/handlers.test.ts`, following that file's existing pattern for building a real `jobs` row and a feed/article fixture for `handleReloadJob`:

```ts
  it("reports progress while reloading and reaches 100 on success", async () => {
    const { job, articleId } = await seedReloadJob();
    const { getJob } = await import("@/lib/jobs/queue");
    const { handleReloadJob } = await import("./reload");

    expect(getJob(job.id)!.progress).toBe(0);
    await handleReloadJob(job);

    expect(getJob(job.id)!.progress).toBe(100);
    expect(articleId).toBeGreaterThan(0);
  });
```

If `handlers.test.ts` has no `seedReloadJob` helper yet, factor one out of that file's existing `handleReloadJob` test rather than duplicating its fixture setup, and have it return `{ job, articleId }`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/lib/jobs/handlers/handlers.test.ts`
Expected: FAIL — progress stays 0, because `handleReloadJob` never reports any.

- [ ] **Step 3: Report progress at the existing phase boundaries**

In `src/lib/jobs/handlers/reload.ts`, change the import to `import { appendLogLine, progress } from "../queue";` and add calls at the boundaries the handler already has. The numbers are fixed, not computed: a reload's phases have no countable work to divide.

- Immediately after the `feed` lookup succeeds (before `createAggregator`): `progress(job.id, 5);`
- Immediately after `freshHtml` is fetched successfully (after the `try/catch`): `progress(job.id, 30);`
- Immediately after `rawArticle.content = await aggregator.extractContent(...)` and its empty check: `progress(job.id, 55);`
- Immediately after `applyAiOptions(...)` returns: `progress(job.id, 80);`
- Immediately after the `writeTransaction` that updates the article row, next to `appendLogLine(job.id, "stdout", "reloaded article content")`: `progress(job.id, 100);`

Leave the failed-refetch early-return branch without a progress call: that path ends the job, and `publishJobOutcome` reports where it got to.

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run src/lib/jobs/handlers/handlers.test.ts`
Expected: PASS

- [ ] **Step 5: Run the whole server suite**

Run: `npx vitest run`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/lib/jobs/handlers/reload.ts src/lib/jobs/handlers/handlers.test.ts
git commit -m "Report reload progress so a single-article reload has a percentage to show"
```

---

## Part B — Client (`yana-ios`)

All Part B commands run from the worktree root.

### Task 5: Wire types

**Files:**
- Create: `Yana/Networking/JobStatus.swift`
- Modify: `Yana/Networking/RunStatus.swift:6-14`
- Test: `YanaTests/JobStatusTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct JobStatusResponse: Decodable, Equatable, Sendable` with `jobId: Int`, `runId: Int?`, `kind: String`, `progress: Int`, `status: String`, `error: String`, `startedAt: String?`, `finishedAt: String?`, plus `var isTerminal: Bool` and `var didSucceed: Bool`.
  - `RunStatusResponse` gains `let progress: Int`, `var isTerminal: Bool`, `var didSucceed: Bool`; keeps `isRunning`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/JobStatusTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("Job and run status wire shapes")
struct JobStatusTests {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: json.data(using: .utf8)!)
    }

    @Test func jobStatusDecodesARunningReloadJob() throws {
        let job: JobStatusResponse = try decode("""
        {"jobId":42,"runId":null,"kind":"article.reload","progress":55,"status":"running",
         "error":"","startedAt":"2026-09-01T10:00:00.000Z","finishedAt":null}
        """)
        #expect(job.jobId == 42)
        #expect(job.runId == nil)
        #expect(job.progress == 55)
        #expect(!job.isTerminal)
        #expect(!job.didSucceed)
    }

    @Test func jobStatusTreatsEveryTerminalStatusAsTerminalAndOnlyCompletedAsSuccess() throws {
        for status in ["completed", "failed", "cancelled"] {
            let job: JobStatusResponse = try decode("""
            {"jobId":1,"runId":null,"kind":"article.reload","progress":100,"status":"\(status)",
             "error":"","startedAt":null,"finishedAt":null}
            """)
            #expect(job.isTerminal)
            #expect(job.didSucceed == (status == "completed"))
        }
        for status in ["pending", "running", "cancelling", "something-new"] {
            let job: JobStatusResponse = try decode("""
            {"jobId":1,"runId":null,"kind":"article.reload","progress":0,"status":"\(status)",
             "error":"","startedAt":null,"finishedAt":null}
            """)
            #expect(!job.isTerminal)
        }
    }

    @Test func runStatusCarriesTheServerComputedPercentage() throws {
        let run: RunStatusResponse = try decode("""
        {"runId":5,"status":"running","progress":25,"totalJobs":4,"completedJobs":1,"failedJobs":0}
        """)
        #expect(run.progress == 25)
        #expect(!run.isTerminal)

        let done: RunStatusResponse = try decode("""
        {"runId":5,"status":"completed","progress":100,"totalJobs":4,"completedJobs":4,"failedJobs":0}
        """)
        #expect(done.isTerminal)
        #expect(done.didSucceed)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/JobStatusTests`
Expected: FAIL — `JobStatusResponse` does not exist and `RunStatusResponse` has no `progress`.

- [ ] **Step 3: Write the types**

Create `Yana/Networking/JobStatus.swift`:

```swift
import Foundation

/// `GET /api/v1/jobs/:id`'s response shape (`yana-server`'s
/// `src/app/api/v1/jobs/[id]/route.ts`). This is the durable state a standalone `article.reload`
/// job leaves behind: its `runId` is `null`, so `/runs/:id` can never see it, and its single
/// terminal SSE event is unrecoverable once missed. Being able to ask this row again later is
/// what lets a relaunched app find out how its reload ended.
///
/// `progress` is the progress signal, 0-100, shown verbatim. `status` is decoded as a plain
/// `String` to match the server's own `status` column, so a status this build has never heard of
/// degrades to "not terminal, keep waiting" instead of failing to decode.
///
/// `startedAt`/`finishedAt` are deliberately `String?`, not `Date?`: the server writes them with
/// `toISOString()`, which includes fractional seconds, and `JSONDecoder`'s `.iso8601` strategy
/// (what `YanaAPIClient` configures) rejects those. Nothing in this app reads these two fields, so
/// carrying them as opaque strings keeps the whole response decodable instead of trading a
/// feature nobody uses for a decode failure on every poll.
struct JobStatusResponse: Decodable, Equatable, Sendable {
    let jobId: Int
    let runId: Int?
    let kind: String
    let progress: Int
    let status: String
    let error: String
    let startedAt: String?
    let finishedAt: String?

    /// The work has ended, whatever the result. The only thing that ends monitoring.
    var isTerminal: Bool {
        status == "completed" || status == "failed" || status == "cancelled"
    }

    var didSucceed: Bool { status == "completed" }
}
```

In `Yana/Networking/RunStatus.swift`, extend `RunStatusResponse`:

```swift
struct RunStatusResponse: Decodable, Equatable, Sendable {
    let runId: Int
    let status: String
    /// The server's own completion percentage for this run (0-100), computed from its counters so
    /// every client shows the same number. Displayed verbatim.
    let progress: Int
    let totalJobs: Int
    let completedJobs: Int
    let failedJobs: Int

    var isRunning: Bool { status == "running" }
    /// A run is `running`, `completed` or `failed` server-side, so anything that is not still
    /// running has ended.
    var isTerminal: Bool { !isRunning }
    var didSucceed: Bool { status == "completed" }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/JobStatusTests`
Expected: PASS. Existing `UpdateAndSyncTests` will now fail to decode their run stubs; Task 10 rewrites that file. If the build breaks before then, add `"progress":0,` to the run JSON stubs in `YanaTests/UpdateAndSyncTests.swift` as part of this task's commit.

- [ ] **Step 5: Commit**

```bash
git add Yana/Networking/JobStatus.swift Yana/Networking/RunStatus.swift YanaTests/JobStatusTests.swift YanaTests/UpdateAndSyncTests.swift
git commit -m "Decode the job route and the run route's percentage"
```

---

### Task 6: `TrackedOperation` and its persistence

**Files:**
- Create: `Yana/Models/TrackedOperation.swift`
- Modify: `Yana/Models/AppSettings.swift` (key list around line 86-99, accessor near `pendingWrites` at line 192)
- Test: `YanaTests/TrackedOperationTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct TrackedOperation: Codable, Equatable, Sendable` with `enum Kind: Codable, Equatable, Sendable { case reloadArticle(serverID: Int); case updateAll }`, `let kind: Kind`, `let id: Int`, `let startedAt: Date`.
  - `AppSettings.trackedOperations: [TrackedOperation]` (get/set, observable, JSON in `UserDefaults` under `"settings.trackedOperations"`).

- [ ] **Step 1: Write the failing test**

Create `YanaTests/TrackedOperationTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("TrackedOperation persistence")
@MainActor
struct TrackedOperationTests {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "TrackedOperationTests.\(UUID())")!)
    }

    @Test func defaultsToNoTrackedOperations() {
        #expect(makeSettings().trackedOperations.isEmpty)
    }

    @Test func roundTripsThroughUserDefaults() {
        let settings = makeSettings()
        let reload = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                      startedAt: Date(timeIntervalSince1970: 1_000))
        let update = TrackedOperation(kind: .updateAll, id: 5,
                                      startedAt: Date(timeIntervalSince1970: 2_000))
        settings.trackedOperations = [reload, update]

        #expect(settings.trackedOperations == [reload, update])
        #expect(settings.trackedOperations.first?.kind == .reloadArticle(serverID: 100))
    }

    @Test func survivesAFreshSettingsInstanceOverTheSameDefaults() {
        let suite = "TrackedOperationTests.\(UUID())"
        let first = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        first.trackedOperations = [
            TrackedOperation(kind: .updateAll, id: 7, startedAt: Date(timeIntervalSince1970: 1))
        ]

        // Standing in for a relaunch: a new AppSettings over the same stored defaults.
        let second = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(second.trackedOperations.count == 1)
        #expect(second.trackedOperations.first?.id == 7)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TrackedOperationTests`
Expected: FAIL — `TrackedOperation` does not exist.

- [ ] **Step 3: Write the model**

Create `Yana/Models/TrackedOperation.swift`:

```swift
import Foundation

/// One server-side operation this device triggered and is waiting on.
///
/// Persisted (`AppSettings.trackedOperations`) rather than held in memory, because the whole point
/// is that the wait outlives the view that started it and, if the app is killed, the process too:
/// on the next launch `OperationMonitor.resume()` reads these back and picks the same monitoring
/// up. A record is written the moment the triggering POST acks with an id, and removed only once a
/// terminal status has been observed and its follow-up work applied.
struct TrackedOperation: Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        /// `POST /api/v1/articles/:id/reload`. `id` is the job id; the article is carried
        /// separately because the job row does not name it in a form this client reads.
        case reloadArticle(serverID: Int)
        /// `POST /api/v1/aggregate`. `id` is the run id.
        case updateAll
    }

    let kind: Kind
    /// The job id for `.reloadArticle`, the run id for `.updateAll` -- the two live in different
    /// server-side tables and are polled through different routes, so `kind` alone says which.
    let id: Int
    let startedAt: Date
}
```

- [ ] **Step 4: Add the settings accessor**

In `Yana/Models/AppSettings.swift`, add the key next to `pendingWrites`:

```swift
        static let trackedOperations = "settings.trackedOperations"
```

and the accessor next to `pendingWrites`'s, following that property's exact shape:

```swift
    /// Server-side operations this device triggered and has not yet seen finish. Survives a
    /// relaunch on purpose -- see `TrackedOperation`.
    var trackedOperations: [TrackedOperation] {
        get {
            access(keyPath: \.trackedOperations)
            guard let data = defaults.data(forKey: Key.trackedOperations),
                  let decoded = try? JSONDecoder().decode([TrackedOperation].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            withMutation(keyPath: \.trackedOperations) {
                let data = try? JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Key.trackedOperations)
            }
        }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/TrackedOperationTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Yana/Models/TrackedOperation.swift Yana/Models/AppSettings.swift YanaTests/TrackedOperationTests.swift
git commit -m "Persist the operations this device is waiting on"
```

---

### Task 7: `OperationMonitor` polling core

**Files:**
- Create: `Yana/Services/OperationMonitor.swift`
- Test: `YanaTests/OperationMonitorTests.swift` (create)

**Interfaces:**
- Consumes: `TrackedOperation`, `JobStatusResponse`, `RunStatusResponse`, `YanaAPIClient`, `AppSettings`.
- Produces:
  - `@MainActor @Observable final class OperationMonitor` with `static let shared`, `private(set) var progressPercent: Int?`, `private(set) var isActive: Bool`, `private(set) var lastOutcome: OperationOutcome?`.
  - `init(pollInterval: Duration = .seconds(2), slowPollInterval: Duration = .seconds(5), youngPhase: Duration = .seconds(60), nudgeSlice: Duration = .milliseconds(250))`.
  - `@discardableResult func track(_ operation: TrackedOperation, settings: AppSettings, container: ModelContainer, client: YanaAPIClient, visibleArticle: Article? = nil) -> Task<Void, Never>`.
  - `enum OperationOutcome: Equatable, Sendable { case reloaded(articleServerID: Int, feedName: String?); case updated(newCount: Int); case failed(TrackedOperation.Kind); case unconfirmed(TrackedOperation.Kind) }`.
- This task implements the poll loop and the published state only. The terminal follow-through (content apply / sync) is a stub returning `.unconfirmed`; Task 8 fills it in. `resume()` and SSE are Task 9.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/OperationMonitorTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@Suite("OperationMonitor", .serialized)
@MainActor
struct OperationMonitorTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self,
                           configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "OperationMonitorTests.\(UUID())")!)
    }

    /// A monitor with intervals short enough that a test finishes in milliseconds.
    private func makeMonitor() -> OperationMonitor {
        OperationMonitor(pollInterval: .milliseconds(5), slowPollInterval: .milliseconds(5),
                         youngPhase: .seconds(60), nudgeSlice: .milliseconds(1))
    }

    private func client(_ stub: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = stub
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t",
                             session: URLSession(configuration: config))
    }

    private func json(_ request: URLRequest, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                         headerFields: ["Content-Type": "application/json"])!,
         body.data(using: .utf8)!)
    }

    @Test func keepsPollingWhileTheJobIsPendingAndRunningAndPublishesEachPercentage() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var seen: [Int] = []
            var call = 0
            let api = client { request in
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                call += 1
                let (status, progress) = switch call {
                case 1: ("pending", 0)
                case 2: ("running", 55)
                default: ("completed", 100)
                }
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":\(progress),
                 "status":"\(status)","error":"","startedAt":null,"finishedAt":null}
                """)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            let task = monitor.track(operation, settings: settings, container: container,
                                     client: api, observer: { seen.append($0 ?? -1) })
            await task.value

            #expect(call == 3)
            #expect(seen.contains(0))
            #expect(seen.contains(55))
            #expect(monitor.isActive == false)
        }
    }

    @Test func stopsOnAFailedJobAndClearsThePersistedRecord() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var contentFetches = 0
            let api = client { request in
                if request.url!.path == "/api/v1/articles/100/content" { contentFetches += 1 }
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":30,"status":"failed",
                 "error":"boom","startedAt":null,"finishedAt":null}
                """)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value

            #expect(contentFetches == 0)
            #expect(settings.trackedOperations.isEmpty)
            #expect(monitor.lastOutcome == .failed(.reloadArticle(serverID: 100)))
        }
    }

    @Test func pollsTheRunRouteForAnUpdateAllOperation() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var runCalls = 0
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    runCalls += 1
                    let running = runCalls < 2
                    return self.json(request, """
                    {"runId":5,"status":"\(running ? "running" : "completed")",
                     "progress":\(running ? 50 : 100),"totalJobs":2,
                     "completedJobs":\(running ? 1 : 2),"failedJobs":0}
                    """)
                case "/api/v1/feeds": return self.json(request, #"{"feeds":[]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .updateAll, id: 5, startedAt: .now)
            settings.trackedOperations = [operation]
            var seen: [Int] = []
            await monitor.track(operation, settings: settings, container: container, client: api,
                                observer: { seen.append($0 ?? -1) }).value

            #expect(runCalls == 2)
            #expect(seen.contains(50))
            #expect(settings.trackedOperations.isEmpty)
        }
    }

    @Test func aTransportFailureRetriesInsteadOfEndingTheWait() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var call = 0
            let api = client { request in
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                call += 1
                // Two undecodable 500s -- YanaAPIClient reports these as .unexpectedStatus, the
                // same class of blip as a dropped packet. Neither may end the wait.
                if call <= 2 {
                    return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                            headerFields: nil)!, "not json".data(using: .utf8)!)
                }
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                 "status":"completed","error":"","startedAt":null,"finishedAt":null}
                """)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value

            #expect(call == 3)
            #expect(settings.trackedOperations.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/OperationMonitorTests`
Expected: FAIL — `OperationMonitor` does not exist.

- [ ] **Step 3: Write the monitor**

Create `Yana/Services/OperationMonitor.swift`:

```swift
import Foundation
import SwiftData

/// What a monitored operation turned out to be. Published by `OperationMonitor` rather than
/// returned to the caller, because by the time the truth arrives the view that triggered the work
/// may be gone, and so may the whole process.
enum OperationOutcome: Equatable, Sendable {
    case reloaded(articleServerID: Int, feedName: String?)
    case updated(newCount: Int)
    case failed(TrackedOperation.Kind)
    /// The server's answer could not be obtained -- its job row was pruned before this device
    /// looked. Whatever content could be fetched has been applied, but nothing here confirms the
    /// work finished, so this must never be reported as success.
    case unconfirmed(TrackedOperation.Kind)
}

/// Waits for server-side operations to actually finish, and reports what really happened.
///
/// The durable `jobs`/`runs` rows are the source of truth: this polls `GET /api/v1/jobs/:id` or
/// `GET /api/v1/runs/:id` until the row reports a terminal status, and shows the `progress`
/// percentage those routes return. **No timeout is ever treated as success.** The predecessor of
/// this type waited ten seconds for a single SSE event and then fetched the article anyway and
/// reported "Reloaded", which meant every reload slower than ten seconds -- the normal case, since
/// the server's worker claims pending jobs on a two-second poll and then refetches and re-extracts
/// the page under a 300s budget -- announced success while displaying the pre-reload content.
///
/// A transport failure retries rather than ending the wait, and the operation stays persisted in
/// `AppSettings.trackedOperations` throughout, so a relaunch resumes the same wait through the
/// same code path (`resume()`) rather than through a second recovery mechanism.
@MainActor
@Observable
final class OperationMonitor {
    static let shared = OperationMonitor()

    /// The newest percentage across the operations in flight, 0-100 exactly as the wire carries
    /// it, `nil` when nothing is running. With more than one operation this is whichever reported
    /// most recently.
    private(set) var progressPercent: Int?
    private(set) var isActive: Bool = false
    /// The most recent finished operation. Views observe this to show a toast.
    private(set) var lastOutcome: OperationOutcome?

    private var inFlight: [Int: Task<Void, Never>] = [:]
    /// The reader's already-registered `Article` object for a reload, when there is one. Not part
    /// of `TrackedOperation` because it cannot be persisted; absent after a relaunch, which is
    /// fine, since a freshly launched reader fetches the row after the write anyway.
    private var visibleArticles: [Int: WeakArticle] = [:]

    private let pollInterval: Duration
    private let slowPollInterval: Duration
    private let youngPhase: Duration
    private let nudgeSlice: Duration

    init(pollInterval: Duration = .seconds(2), slowPollInterval: Duration = .seconds(5),
         youngPhase: Duration = .seconds(60), nudgeSlice: Duration = .milliseconds(250)) {
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.youngPhase = youngPhase
        self.nudgeSlice = nudgeSlice
    }

    /// Begins (or resumes) monitoring one operation. The caller is expected to have persisted it
    /// into `settings.trackedOperations` already, so a crash between the POST ack and this call
    /// still leaves a record for `resume()` to find.
    ///
    /// `observer` exists for tests, which need to see every published percentage rather than only
    /// the last one; production passes nothing.
    @discardableResult
    func track(
        _ operation: TrackedOperation, settings: AppSettings, container: ModelContainer,
        client: YanaAPIClient, visibleArticle: Article? = nil,
        observer: ((Int?) -> Void)? = nil
    ) -> Task<Void, Never> {
        if let existing = inFlight[operation.id] { return existing }
        if let visibleArticle { visibleArticles[operation.id] = WeakArticle(visibleArticle) }
        isActive = true

        let task = Task { @MainActor in
            let outcome = await self.monitor(operation, settings: settings, container: container,
                                             client: client, observer: observer)
            self.inFlight[operation.id] = nil
            self.visibleArticles[operation.id] = nil
            settings.trackedOperations.removeAll { $0.id == operation.id && $0.kind == operation.kind }
            if let outcome { self.lastOutcome = outcome }
            self.isActive = !self.inFlight.isEmpty
            if !self.isActive { self.progressPercent = nil }
        }
        inFlight[operation.id] = task
        return task
    }

    /// Polls until the row reports a terminal status, then hands off to the follow-through.
    /// Returns `nil` only when the task itself was cancelled, which is "stop watching", not an
    /// outcome to report.
    private func monitor(
        _ operation: TrackedOperation, settings: AppSettings, container: ModelContainer,
        client: YanaAPIClient, observer: ((Int?) -> Void)?
    ) async -> OperationOutcome? {
        let startedMonitoringAt = ContinuousClock.now
        var sawTheRowAlive = false

        while !Task.isCancelled {
            let poll = await pollOnce(operation, client: client)
            switch poll {
            case .state(let percent, let terminal, let succeeded):
                sawTheRowAlive = true
                publish(percent, observer: observer)
                if terminal {
                    guard succeeded else { return .failed(operation.kind) }
                    return await applyTerminalSuccess(operation, container: container,
                                                      client: client, settings: settings)
                }
            case .gone:
                // The row was pruned out from under the poll. Anything fetchable is applied, but
                // nothing here says the work finished, so it is reported as unconfirmed.
                guard sawTheRowAlive else { return .unconfirmed(operation.kind) }
                _ = await applyTerminalSuccess(operation, container: container, client: client,
                                               settings: settings)
                return .unconfirmed(operation.kind)
            case .retryable:
                // A dropped packet, a proxy's 502, or being offline entirely. None of those are
                // the operation's outcome, so the wait continues and the record stays persisted.
                break
            }

            let interval = ContinuousClock.now - startedMonitoringAt < youngPhase
                ? pollInterval : slowPollInterval
            await sleep(interval)
        }
        return nil
    }

    private enum PollResult {
        case state(percent: Int, terminal: Bool, succeeded: Bool)
        case gone
        case retryable
    }

    private func pollOnce(_ operation: TrackedOperation, client: YanaAPIClient) async -> PollResult {
        do {
            switch operation.kind {
            case .reloadArticle:
                let job: JobStatusResponse = try await client.get("/api/v1/jobs/\(operation.id)")
                return .state(percent: job.progress, terminal: job.isTerminal,
                              succeeded: job.didSucceed)
            case .updateAll:
                let run: RunStatusResponse = try await client.get("/api/v1/runs/\(operation.id)")
                return .state(percent: run.progress, terminal: run.isTerminal,
                              succeeded: run.didSucceed)
            }
        } catch YanaAPIClientError.server(let error) where error.code == "not_found" {
            return .gone
        } catch YanaAPIClientError.unexpectedStatus(404) {
            return .gone
        } catch {
            return .retryable
        }
    }

    private func publish(_ percent: Int, observer: ((Int?) -> Void)?) {
        progressPercent = percent
        observer?(percent)
    }

    /// Sleeps in slices so a live SSE event (Task 9) can shorten the wait without any continuation
    /// bookkeeping. The cost is at most one slice of added latency.
    private func sleep(_ total: Duration) async {
        var remaining = total
        while remaining > .zero, !Task.isCancelled {
            let slice = remaining < nudgeSlice ? remaining : nudgeSlice
            try? await Task.sleep(for: slice)
            remaining -= slice
        }
    }

    /// Filled in by the terminal follow-through task. Until then, nothing is fetched.
    private func applyTerminalSuccess(
        _ operation: TrackedOperation, container: ModelContainer, client: YanaAPIClient,
        settings: AppSettings
    ) async -> OperationOutcome {
        .unconfirmed(operation.kind)
    }
}

/// A non-owning box so a monitored reload cannot keep the reader's `Article` alive past its
/// context.
private final class WeakArticle {
    weak var article: Article?
    init(_ article: Article) { self.article = article }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/OperationMonitorTests`
Expected: the pending/running/completed, failed, and transport-retry tests PASS. The `.updateAll` test's assertion that `settings.trackedOperations` is emptied PASSES; its sync-side effects are Task 8.

- [ ] **Step 5: Commit**

```bash
git add Yana/Services/OperationMonitor.swift YanaTests/OperationMonitorTests.swift
git commit -m "Poll a job or run until the server says it ended, never a timeout"
```

---

### Task 8: Terminal follow-through

**Files:**
- Modify: `Yana/Services/OperationMonitor.swift` (`applyTerminalSuccess`)
- Modify: `Yana/Services/UpdateAndSync.swift` (move `fetchAndApplyContent` in, delete the two poll entry points and the SSE-timeout wait)
- Test: `YanaTests/OperationMonitorTests.swift`

**Interfaces:**
- Consumes: `SyncWriter.applyContent(articleServerID:document:)`, `SyncWriter.articleTitle(serverID:)`, `SyncEngine(container:client:settings:).sync()`, `Block.preservingSummary(from:in:)`, `OffMainActor.run`.
- Produces: `applyTerminalSuccess` returning `.reloaded(articleServerID:feedName:)` or `.updated(newCount:)`.

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/OperationMonitorTests.swift`:

```swift
    @Test func aCompletedReloadAppliesTheContentToTheVisibleArticle() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", identifier: "f1", tagIds: [], logoImageHash: nil)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Old", identifier: "art-100",
                                       date: .now, author: "", read: false, starred: false,
                                       createdAt: .now, updatedAt: .now)
            ])
            let readerContext = ModelContext(container)
            let visible = try readerContext.fetch(
                FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == 100 })
            ).first!

            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    return self.json(request, """
                    {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                     "status":"completed","error":"","startedAt":null,"finishedAt":null}
                    """)
                case "/api/v1/articles/100/content":
                    return self.json(request, #"""
                    {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"fresh","styles":[],"link":null}]}]}
                    """#)
                case "/api/v1/feeds": return self.json(request, #"{"feeds":[]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api,
                                visibleArticle: visible).value

            #expect(visible.hasContent)
            #expect(visible.plainText.contains("fresh"))
            #expect(monitor.lastOutcome == .reloaded(articleServerID: 100, feedName: "Feed"))
        }
    }

    @Test func aCompletedUpdateAllSyncsOnceAndReportsTheNewCount() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var syncCalls = 0
            let syncBody = #"""
            {"new":[{"id":100,"feedId":1,"name":"New","identifier":"art-100","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"updated":[],"removed":[],"nextCursor":null}
            """#
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    return self.json(request, """
                    {"runId":5,"status":"completed","progress":100,"totalJobs":1,
                     "completedJobs":1,"failedJobs":0}
                    """)
                case "/api/v1/feeds":
                    return self.json(request, #"{"feeds":[{"id":1,"name":"Feed","identifier":"f1","tagIds":[],"logoImageHash":null}]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    syncCalls += 1
                    return self.json(request, syncCalls == 1
                        ? syncBody
                        : #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .updateAll, id: 5, startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api).value

            #expect(monitor.lastOutcome == .updated(newCount: 1))
        }
    }

    @Test func aPrunedJobRowAppliesContentButReportsItAsUnconfirmed() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", identifier: "f1", tagIds: [], logoImageHash: nil)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Old", identifier: "art-100",
                                       date: .now, author: "", read: false, starred: false,
                                       createdAt: .now, updatedAt: .now)
            ])
            var jobCalls = 0
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    jobCalls += 1
                    if jobCalls == 1 {
                        return self.json(request, """
                        {"jobId":42,"runId":null,"kind":"article.reload","progress":10,
                         "status":"running","error":"","startedAt":null,"finishedAt":null}
                        """)
                    }
                    return self.json(request, #"{"error":{"code":"not_found","message":"gone"}}"#,
                                     status: 404)
                case "/api/v1/articles/100/content":
                    return self.json(request, #"{"version":1,"blocks":[]}"#)
                case "/api/v1/feeds": return self.json(request, #"{"feeds":[]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api).value

            #expect(monitor.lastOutcome == .unconfirmed(.reloadArticle(serverID: 100)))
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/OperationMonitorTests`
Expected: FAIL — the stub `applyTerminalSuccess` fetches nothing and always reports `.unconfirmed`.

- [ ] **Step 3: Implement the follow-through**

Replace the stub in `Yana/Services/OperationMonitor.swift`:

```swift
    /// The work the server just finished, pulled down. For a reload this deliberately does NOT go
    /// through `SyncEngine`'s generic `hasContent`-gated backfill: that backfill sets
    /// `hasContent = true` and nothing ever resets it, so a fetch racing the poll would
    /// permanently block any later retry of this exact article.
    private func applyTerminalSuccess(
        _ operation: TrackedOperation, container: ModelContainer, client: YanaAPIClient,
        settings: AppSettings
    ) async -> OperationOutcome {
        switch operation.kind {
        case .reloadArticle(let articleServerID):
            let visible = visibleArticles[operation.id]?.article
            let applied = await Self.fetchAndApplyContent(
                articleServerID: articleServerID, container: container, client: client,
                visibleArticle: visible, settings: settings
            )
            guard applied else { return .failed(operation.kind) }
            return .reloaded(articleServerID: articleServerID, feedName: visible?.feed?.name)
        case .updateAll:
            let engine = SyncEngine(container: container, client: client, settings: settings)
            let result = (try? await engine.sync())
                ?? SyncResult(newCount: 0, updatedCount: 0, removedCount: 0)
            return .updated(newCount: result.newCount)
        }
    }
```

Move `fetchAndApplyContent` out of `UpdateAndSync` into `OperationMonitor` as a `static` method, unchanged apart from taking `settings` and being `static`. Keep both of its existing behaviours and their comments verbatim: the direct write to the caller's already-registered `Article` (a sibling context's save does not refresh a registered object's attributes, so without this the reader keeps rendering stale content), and `Block.preservingSummary(from:in:)` on that write, matching what `SyncWriter.applyContent` does, so a locally generated summary survives a reload.

- [ ] **Step 4: Delete the superseded entry points**

From `Yana/Services/UpdateAndSync.swift`, delete `pollForFreshContent`, `waitForRunToFinish`, `pollForReloadedContent`, `waitForReloadJobOutcome`, and `fetchAndApplyContent`. If nothing remains, delete the file and remove it from `project.yml`'s sources if it is listed individually, then run `xcodegen generate`. Do not delete `Yana/Networking/JobEventsClient.swift` or `SSEFrameAccumulator.swift`: Task 9 and `ReadingPositionLiveSync` both use them.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/OperationMonitorTests`
Expected: PASS. `YanaTests/UpdateAndSyncTests.swift` will no longer compile; delete it in this step, having first confirmed its two regression cases are covered above (`aCompletedReloadAppliesTheContentToTheVisibleArticle` covers the visible-object write; the updated-title case moves to Task 8's commit as the test below).

Add the title regression to `OperationMonitorTests`, keeping the behaviour `UpdateAndSyncTests.pollForReloadedContentPicksUpAnUpdatedTitleViaSync` pinned:

```swift
    @Test func aCompletedReloadPicksUpARewrittenTitleViaTheFollowUpSync() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", identifier: "f1", tagIds: [], logoImageHash: nil)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Old Title", identifier: "art-100",
                                       date: .now, author: "", read: false, starred: false,
                                       createdAt: .now, updatedAt: .now)
            ])
            let readerContext = ModelContext(container)
            let visible = try readerContext.fetch(
                FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == 100 })
            ).first!
            #expect(visible.title == "Old Title")

            let syncBody = #"""
            {"new":[],"updated":[{"id":100,"feedId":1,"name":"New Title","identifier":"art-100","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}],"removed":[],"nextCursor":null}
            """#
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    return self.json(request, """
                    {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                     "status":"completed","error":"","startedAt":null,"finishedAt":null}
                    """)
                case "/api/v1/articles/100/content":
                    return self.json(request, #"{"version":1,"blocks":[]}"#)
                case "/api/v1/feeds": return self.json(request, #"{"feeds":[]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync": return self.json(request, syncBody)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api,
                                visibleArticle: visible).value

            #expect(visible.title == "New Title")
        }
    }
```

- [ ] **Step 6: Commit**

```bash
git add Yana/Services/OperationMonitor.swift Yana/Services/UpdateAndSync.swift YanaTests project.yml
git commit -m "Pull down what the finished operation produced, and report what really happened"
```

---

### Task 9: SSE acceleration and resume

**Files:**
- Modify: `Yana/Services/OperationMonitor.swift`
- Modify: `Yana/YanaApp.swift:146-183` (scene `.task`) and `:124-141` (`scenePhase` handler)
- Test: `YanaTests/OperationMonitorTests.swift`

**Interfaces:**
- Consumes: `JobEventsClient(client:).events()`, `JobEvent.job(JobEventPayload)`, `AuthenticatedClient.current(settings:)`.
- Produces:
  - `func startEvents(settings: AppSettings, clientProvider: @escaping (AppSettings) -> YanaAPIClient?)` and `func stopEvents()`.
  - `@discardableResult func resume(settings: AppSettings, container: ModelContainer, clientProvider: (AppSettings) -> YanaAPIClient? = { AuthenticatedClient.current(settings: $0) }) -> [Task<Void, Never>]` — returns the tasks it started, for tests.
  - `func stopWatching(settings: AppSettings)` — cancels every poll and clears the persisted records, without asking the server to stop.

- [ ] **Step 1: Write the failing tests**

Add to `YanaTests/OperationMonitorTests.swift`:

```swift
    @Test func resumeMonitorsARecordPersistedByAPreviousSession() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            // Written by a previous launch; nothing in this session triggered it.
            settings.trackedOperations = [
                TrackedOperation(kind: .updateAll, id: 5, startedAt: Date(timeIntervalSince1970: 1))
            ]
            var runCalls = 0
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    runCalls += 1
                    return self.json(request, """
                    {"runId":5,"status":"completed","progress":100,"totalJobs":1,
                     "completedJobs":1,"failedJobs":0}
                    """)
                case "/api/v1/feeds": return self.json(request, #"{"feeds":[]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let tasks = monitor.resume(settings: settings, container: container,
                                       clientProvider: { _ in api })
            for task in tasks { await task.value }

            #expect(runCalls == 1)
            #expect(settings.trackedOperations.isEmpty)
            #expect(monitor.lastOutcome == .updated(newCount: 0))
        }
    }

    @Test func resumeIsIdempotentSoAForegroundCallDoesNotDoubleMonitor() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            settings.trackedOperations = [
                TrackedOperation(kind: .updateAll, id: 5, startedAt: .now)
            ]
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    return self.json(request, """
                    {"runId":5,"status":"running","progress":10,"totalJobs":1,
                     "completedJobs":0,"failedJobs":0}
                    """)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let first = monitor.resume(settings: settings, container: container,
                                       clientProvider: { _ in api })
            let second = monitor.resume(settings: settings, container: container,
                                        clientProvider: { _ in api })
            #expect(first.count == 1)
            #expect(second.isEmpty)
            monitor.stopWatching(settings: settings)
            for task in first { await task.value }
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/OperationMonitorTests`
Expected: FAIL — `resume` and `stopWatching` do not exist.

- [ ] **Step 3: Add `resume` and `stopWatching`**

In `OperationMonitor`:

```swift
    /// Picks monitoring back up for everything persisted, whether this session triggered it or a
    /// previous one did. Called at launch and whenever the app returns to the foreground; the
    /// per-operation guard in `track` makes repeat calls free, so callers never have to reason
    /// about whether monitoring is already running.
    ///
    /// Returns the tasks it started, for tests. Production ignores the result.
    @discardableResult
    func resume(
        settings: AppSettings, container: ModelContainer,
        clientProvider: (AppSettings) -> YanaAPIClient? = { AuthenticatedClient.current(settings: $0) }
    ) -> [Task<Void, Never>] {
        guard let client = clientProvider(settings) else { return [] }
        return settings.trackedOperations.compactMap { operation in
            guard inFlight[operation.id] == nil else { return nil }
            return track(operation, settings: settings, container: container, client: client)
        }
    }

    /// Stop watching on this device, without asking the server to stop working. The persisted
    /// records go with it: the user asked for the spinner to end, and whatever the server produces
    /// still arrives through the next ordinary sync.
    func stopWatching(settings: AppSettings) {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        visibleArticles.removeAll()
        settings.trackedOperations = []
        isActive = false
        progressPercent = nil
    }
```

- [ ] **Step 4: Add the SSE accelerator**

In `OperationMonitor`, add a long-lived subscription that only ever moves numbers earlier:

```swift
    private var eventTask: Task<Void, Never>?

    /// Subscribes to `GET /api/v1/jobs/events` for as long as the app is foregrounded, purely to
    /// learn a percentage sooner than the next poll would. It never decides an outcome: a missed
    /// or duplicated event costs nothing, because the poll below is what actually ends the wait.
    /// Started before any operation is triggered, so a job that finishes in the moment between a
    /// POST and its first poll cannot slip through a connect gap.
    func startEvents(
        settings: AppSettings,
        clientProvider: @escaping @Sendable (AppSettings) -> YanaAPIClient? = {
            AuthenticatedClient.current(settings: $0)
        },
        reconnectDelay: Duration = .seconds(5)
    ) {
        guard eventTask == nil else { return }
        eventTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let client = clientProvider(settings) else {
                    try? await Task.sleep(for: reconnectDelay)
                    continue
                }
                var iterator = JobEventsClient(client: client).events().makeAsyncIterator()
                while let event = try? await iterator.next() {
                    guard let self else { return }
                    if case let .job(payload) = event, self.inFlight[payload.jobId] != nil {
                        self.progressPercent = Int(payload.progress)
                    }
                    if case let .run(payload) = event, self.inFlight[payload.runId] != nil {
                        self.progressPercent = payload.progress
                    }
                }
                try? await Task.sleep(for: reconnectDelay)
            }
        }
    }

    func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
    }
```

Add `let progress: Int` to `RunEventPayload` in `Yana/Networking/JobEvent.swift`, matching Task 1's server-side addition, and update its doc comment to say the field is the run's server-computed completion percentage.

- [ ] **Step 5: Wire it into the app lifecycle**

In `Yana/YanaApp.swift`'s scene `.task`, right after the `InitialSyncGate.run` block and next to the existing `ReadingPositionLiveSync.shared.start(settings:)` call:

```swift
                    // Anything this device triggered and never saw finish -- including in a
                    // previous launch -- is picked back up here, through the same path a fresh
                    // trigger takes.
                    OperationMonitor.shared.startEvents(settings: appSettings)
                    OperationMonitor.shared.resume(settings: appSettings, container: AppContainer.shared)
```

In the `scenePhase` handler, add to the `.active` branch:

```swift
                        OperationMonitor.shared.startEvents(settings: appSettings)
                        OperationMonitor.shared.resume(settings: appSettings, container: AppContainer.shared)
```

and to the `.background` branch, next to `ReadingPositionLiveSync.shared.stop()`:

```swift
                        // No point paying for an open SSE connection while nothing is watching.
                        // The poll loops keep running; they are what actually ends a wait.
                        OperationMonitor.shared.stopEvents()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/OperationMonitorTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Yana/Services/OperationMonitor.swift Yana/Networking/JobEvent.swift Yana/YanaApp.swift YanaTests/OperationMonitorTests.swift
git commit -m "Resume monitoring after a relaunch, and let live events move the number sooner"
```

---

### Task 10: Rewire the triggers

**Files:**
- Modify: `Yana/Services/ReaderActions.swift:98-147`
- Modify: `Yana/Reader/ReaderHostView.swift:441-505`
- Modify: `Yana/Reader/Mac/TimelineModel.swift:359-400`
- Modify: `Yana/Views/Config/ArticleListView.swift:113-139`
- Test: `YanaTests/ReaderActionsTriggerTests.swift` (create)

**Interfaces:**
- Produces:
  - `ReaderActions.startReload(_ article: Article, serverID: Int, client: YanaAPIClient, container: ModelContainer, settings: AppSettings, monitor: OperationMonitor = .shared) async -> Bool` — POSTs the reload, persists the record, hands it to the monitor. `false` means the POST itself failed.
  - `ReaderActions.startUpdateAll(client: YanaAPIClient, container: ModelContainer, settings: AppSettings, monitor: OperationMonitor = .shared) async -> Bool` — same for `/aggregate`.
  - `ForceUpdateResult` and `TriggerRefreshResult` are deleted along with `forceUpdateArticle`/`triggerRefresh`.

- [ ] **Step 1: Write the failing test**

Create `YanaTests/ReaderActionsTriggerTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Yana

@Suite("Reader action triggers", .serialized)
@MainActor
struct ReaderActionsTriggerTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self,
                           configurations: .init(isStoredInMemoryOnly: true))
    }

    @Test func startingAReloadPersistsTheJobBeforeAnythingElseCanLoseIt() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = AppSettings(defaults: UserDefaults(suiteName: "Trigger.\(UUID())")!)
            let article = Article(title: "T", identifier: "a", url: "https://example.test/a")
            article.serverID = 100
            let context = ModelContext(container)
            context.insert(article)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                if request.url!.path == "/api/v1/articles/100/reload" {
                    return (response, #"{"jobId":42}"#.data(using: .utf8)!)
                }
                // Keep the monitor's first poll from finishing the operation during this test.
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                        headerFields: nil)!, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t",
                                       session: URLSession(configuration: config))

            let monitor = OperationMonitor(pollInterval: .seconds(60), slowPollInterval: .seconds(60),
                                           youngPhase: .seconds(60), nudgeSlice: .milliseconds(1))
            let started = await ReaderActions.startReload(
                article, serverID: 100, client: client, container: container, settings: settings,
                monitor: monitor
            )

            #expect(started)
            #expect(settings.trackedOperations == [
                TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                 startedAt: settings.trackedOperations.first!.startedAt)
            ])
            monitor.stopWatching(settings: settings)
        }
    }

    @Test func aFailedTriggerPersistsNothing() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = AppSettings(defaults: UserDefaults(suiteName: "Trigger.\(UUID())")!)
            let article = Article(title: "T", identifier: "a", url: "https://example.test/a")
            article.serverID = 100
            ModelContext(container).insert(article)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                 headerFields: nil)!, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t",
                                       session: URLSession(configuration: config))

            let monitor = OperationMonitor()
            let started = await ReaderActions.startReload(
                article, serverID: 100, client: client, container: container, settings: settings,
                monitor: monitor
            )

            #expect(!started)
            #expect(settings.trackedOperations.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderActionsTriggerTests`
Expected: FAIL — `startReload` does not exist.

- [ ] **Step 3: Replace the two trigger methods**

In `Yana/Services/ReaderActions.swift`, delete `ForceUpdateResult`, `forceUpdateArticle`, `TriggerRefreshResult` and `triggerRefresh`, and add:

```swift
    /// Triggers the server's per-article reload and hands the resulting job to `OperationMonitor`.
    ///
    /// The POST's ack is only a job id, never new content, so there is nothing to report yet: the
    /// monitor is what finds out how the job ended and publishes the outcome. Persisting the
    /// record before returning is deliberate, so an app killed a second later still resumes this
    /// wait on its next launch.
    ///
    /// Returns `false` only when the trigger itself failed.
    @discardableResult
    static func startReload(
        _ article: Article, serverID: Int, client: YanaAPIClient, container: ModelContainer,
        settings: AppSettings, monitor: OperationMonitor = .shared
    ) async -> Bool {
        guard let jobId = try? await ArticleActions(client: client).reload(articleServerID: serverID)
        else { return false }
        let operation = TrackedOperation(kind: .reloadArticle(serverID: serverID), id: jobId,
                                         startedAt: .now)
        settings.trackedOperations.append(operation)
        monitor.track(operation, settings: settings, container: container, client: client,
                      visibleArticle: article)
        return true
    }

    /// Triggers the server's aggregation run over every enabled feed and hands the run to
    /// `OperationMonitor`. Same contract as `startReload`: the ack is a run id, not results.
    @discardableResult
    static func startUpdateAll(
        client: YanaAPIClient, container: ModelContainer, settings: AppSettings,
        monitor: OperationMonitor = .shared
    ) async -> Bool {
        guard let runId = try? await ArticleActions(client: client).updateAll() else { return false }
        let operation = TrackedOperation(kind: .updateAll, id: runId, startedAt: .now)
        settings.trackedOperations.append(operation)
        monitor.track(operation, settings: settings, container: container, client: client)
        return true
    }
```

- [ ] **Step 4: Rewire the three call sites**

`Yana/Reader/ReaderHostView.swift` — replace the body of `forceUpdateArticle(_:)` and `triggerRefresh()`. Neither shows a success toast any more; that arrives via the monitor's outcome (Step 5). Keep only the failure-to-trigger toast:

```swift
    private func forceUpdateArticle(_ article: Article) {
        guard let client = AuthenticatedClient.current(), let serverID = article.serverID else { return }
        Task {
            let started = await ReaderActions.startReload(
                article, serverID: serverID, client: client,
                container: modelContext.container, settings: settings
            )
            if !started {
                toast = ToastMessage(
                    text: String(localized: "Could not reload this article. Please try again."),
                    style: .error
                )
            }
        }
    }

    private func triggerRefresh() {
        guard let client = AuthenticatedClient.current() else {
            toast = ToastMessage(text: String(localized: "Not connected to a server."), style: .error)
            return
        }
        Task {
            let started = await ReaderActions.startUpdateAll(
                client: client, container: modelContext.container, settings: settings
            )
            if !started {
                toast = ToastMessage(
                    text: String(localized: "Could not check for updates. Please try again."),
                    style: .error
                )
            }
        }
    }
```

`Yana/Reader/Mac/TimelineModel.swift` — the same two replacements, using `self.toast` and `modelContext.container`, and dropping the `UpdateActivity.shared.restart` wrapper in both.

`Yana/Views/Config/ArticleListView.swift:114-138` — the swipe action becomes:

```swift
                    Button {
                        guard let article = article(for: summary),
                              let client = AuthenticatedClient.current(),
                              let serverID = article.serverID
                        else { return }
                        Task {
                            let started = await ReaderActions.startReload(
                                article, serverID: serverID, client: client,
                                container: modelContext.container, settings: settings
                            )
                            if !started {
                                toast = ToastMessage(
                                    text: String(localized: "Could not reload this article. Please try again."),
                                    style: .error
                                )
                            }
                        }
                    } label: {
```

If `ArticleListView` has no `settings` in scope, read it from `@Environment(AppSettings.self)` the way its sibling views do.

- [ ] **Step 5: Report outcomes from the monitor**

In `ReaderHostView.swift`, add an observer next to the existing `.onChange` handlers:

```swift
        .onChange(of: OperationMonitor.shared.lastOutcome) { _, outcome in
            guard let outcome else { return }
            switch outcome {
            case .reloaded(_, let feedName):
                // Re-render the visible page: the reload refreshed the article's content, but the
                // reader only re-renders when reloadToken changes (same as summarize).
                reloadToken += 1
                toast = ToastMessage(text: RefreshOutcome.message(newCount: 0, feedName: feedName))
                Haptics.impact(.light)
            case .updated(let newCount):
                toast = ToastMessage(text: RefreshOutcome.message(newCount: newCount, feedName: nil))
                Haptics.impact(.light)
            case .failed:
                toast = ToastMessage(
                    text: String(localized: "Could not reload this article. Please try again."),
                    style: .error
                )
            case .unconfirmed:
                reloadToken += 1
                toast = ToastMessage(text: String(localized: "The server did not confirm this finished, so this might not be the newest version."))
            }
        }
```

Add the same handler to `MacRootView.swift`, assigning to `model.toast` and `model.reloadToken` and omitting the haptics (Catalyst has none).

- [ ] **Step 6: Add the new string with its translation**

In `Yana/Resources/Localizable.xcstrings`, add the key `"The server did not confirm this finished, so this might not be the newest version."` with an `en` localization of the same text and a `de` localization of `"Der Server hat den Abschluss nicht bestätigt. Das ist möglicherweise nicht die neueste Version."`, both `"state" : "translated"`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/ReaderActionsTriggerTests`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Yana/Services/ReaderActions.swift Yana/Reader Yana/Views/Config/ArticleListView.swift Yana/Resources/Localizable.xcstrings YanaTests/ReaderActionsTriggerTests.swift
git commit -m "Trigger, then let the monitor report what actually happened"
```

---

### Task 11: Spinner and percentage

**Files:**
- Modify: `Yana/Services/UpdateActivity.swift:16-62`
- Modify: `Yana/Reader/ReaderArticleViewController.swift:161-164, 308-315, 366-375, 398-405`
- Modify: `Yana/Reader/ReaderHostView.swift:18, 60-100, 228`
- Modify: `Yana/Reader/Mac/MacRootView.swift:123-138, 290-300`
- Modify: `Yana/Views/Config/ArticleListView.swift:170-182`
- Modify: `Yana/Reader/ArticleBlockView.swift:735-752`
- Modify: `Yana/Resources/Localizable.xcstrings`
- Test: `YanaTests/UpdateActivityTests.swift` (create)

**Interfaces:**
- Consumes: `OperationMonitor.shared.isActive`, `OperationMonitor.shared.progressPercent`.
- Produces: `UpdateActivity.progressPercent: Int?` and `UpdateActivity.progressLabel: String?` (`nil` when there is no percentage; otherwise the localized `"%lld%%"`).

- [ ] **Step 1: Write the failing test**

Create `YanaTests/UpdateActivityTests.swift`:

```swift
import Foundation
import Testing
@testable import Yana

@Suite("UpdateActivity progress")
@MainActor
struct UpdateActivityTests {
    @Test func hasNoLabelWithoutAPercentage() {
        let activity = UpdateActivity()
        activity.setProgress(nil)
        #expect(activity.progressPercent == nil)
        #expect(activity.progressLabel == nil)
    }

    @Test func rendersThePercentageVerbatim() {
        let activity = UpdateActivity()
        activity.setProgress(0)
        #expect(activity.progressLabel == String(localized: "\(0)%"))
        activity.setProgress(55)
        #expect(activity.progressLabel == String(localized: "\(55)%"))
        activity.setProgress(100)
        #expect(activity.progressLabel == String(localized: "\(100)%"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UpdateActivityTests`
Expected: FAIL — `setProgress`, `progressPercent` and `progressLabel` do not exist.

- [ ] **Step 3: Extend `UpdateActivity` and delete the 35s cap**

In `Yana/Services/UpdateActivity.swift`, make the class `@Observable` if it is not already, and add:

```swift
    /// The server's own percentage for whatever is running, 0-100, `nil` when there is nothing to
    /// report. Set by `OperationMonitor`; displayed verbatim, with no unit conversion.
    private(set) var progressPercent: Int?

    func setProgress(_ percent: Int?) { progressPercent = percent }

    /// The percentage as shown next to a spinner, or `nil` when there is none.
    var progressLabel: String? {
        guard let progressPercent else { return nil }
        return String(localized: "\(progressPercent)%")
    }
```

Delete `waitUntilIdle` entirely: an operation now runs for as long as the server takes, so nothing may wait on it inline.

- [ ] **Step 4: Drive it from the monitor**

In `OperationMonitor.publish(_:observer:)` and in `track`'s completion block, mirror the value out:

```swift
    private func publish(_ percent: Int, observer: ((Int?) -> Void)?) {
        progressPercent = percent
        UpdateActivity.shared.setProgress(percent)
        observer?(percent)
    }
```

and in `track`'s trailing block, after `self.isActive = !self.inFlight.isEmpty`:

```swift
            if !self.isActive {
                self.progressPercent = nil
                UpdateActivity.shared.setProgress(nil)
            }
```

Have `track` call `UpdateActivity.shared.begin()` and the completion block call `UpdateActivity.shared.end()`, replacing the `UpdateActivity.shared.restart { ... }` wrappers deleted in Task 10, so `isUpdating` still reflects exactly what is running.

- [ ] **Step 5: Show it in the reader toolbar**

In `ReaderArticleViewController`, add a label beside the indicator:

```swift
    private let progressLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        return label
    }()
```

Build `indicatorItem` from a horizontal `UIStackView` of `activityIndicator` and `progressLabel` (spacing 4), and extend `setRefreshing(_:)` to take the label text:

```swift
    func setRefreshing(_ isRefreshing: Bool, progressText: String?) {
        if isRefreshing { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        progressLabel.text = progressText
        progressLabel.isHidden = progressText == nil
        let items: [UIBarButtonItem] = isRefreshing ? [articleListItem, indicatorItem] : [articleListItem]
        ...
    }
```

Update both call sites in `ReaderHostView.swift` (`reader.setRefreshing(isRefreshing, progressText: progressText)`), add `let progressText: String?` next to `let isRefreshing: Bool`, and pass it from `ReaderScreen`:

```swift
                    isRefreshing: UpdateActivity.shared.isUpdating || isSummarizing,
                    progressText: UpdateActivity.shared.progressLabel,
```

- [ ] **Step 6: Show it on the Mac and in the article list**

`MacRootView.swift` — put the percentage next to the toolbar spinner:

```swift
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(showSpinner ? 0 : 1)
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    if let label = UpdateActivity.shared.progressLabel {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .opacity(showSpinner ? 1 : 0)
            }
```

`ArticleListView.swift` — inside the existing `if isUpdating` toolbar item, add the percentage beside the stop control:

```swift
                    HStack(spacing: 4) {
                        Button { OperationMonitor.shared.stopWatching(settings: settings) } label: {
                            ZStack {
                                ProgressView()
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let label = UpdateActivity.shared.progressLabel {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
```

- [ ] **Step 7: Fix pull-to-refresh**

In `Yana/Reader/ArticleBlockView.swift`'s `RefreshableIfAvailable`, replace the body with:

```swift
            content.refreshable {
                onRefresh()
                // Let the trigger's POST land, then hand the gesture back. An operation now runs
                // for as long as the server takes -- minutes, for a full aggregation run -- and a
                // system refresh control cannot stay up that long. The toolbar spinner and its
                // percentage carry the real state, and nothing claims the work is done here.
                try? await Task.sleep(for: .milliseconds(400))
            }
```

- [ ] **Step 8: Add the percentage string**

`String(localized: "\(progressPercent)%")` interpolates an `Int`, so the catalog key is `"%lld%"` — verify the exact key Xcode extracts before hand-writing it. Add that key to `Yana/Resources/Localizable.xcstrings` with an `en` localization of `"%lld%"` and a `de` localization of `"%lld %"` (German puts a space before the percent sign), both `"state" : "translated"`. A bare number with a unit needs no plural variations, per the catalog rules in CLAUDE.md.

- [ ] **Step 9: Run the tests**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:YanaTests/UpdateActivityTests`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add Yana/Services/UpdateActivity.swift Yana/Services/OperationMonitor.swift Yana/Reader Yana/Views/Config/ArticleListView.swift Yana/Resources/Localizable.xcstrings YanaTests/UpdateActivityTests.swift
git commit -m "Show the server's real percentage beside every spinner"
```

---

### Task 12: Full verification

**Files:** none changed unless a failure demands it.

- [ ] **Step 1: Build the Mac Catalyst target**

Run: `xcodebuild -scheme Yana -destination 'platform=macOS,variant=Mac Catalyst' build`
Expected: BUILD SUCCEEDED. Catalyst is not covered by the simulator test run, and both `MacRootView` and `TimelineModel` changed.

- [ ] **Step 2: Run the whole client suite**

Run: `xcodebuild -scheme Yana -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: PASS. If `SyncReactionMainThreadTests.importBatchesLeaveTheMainActorResponsive` fails, re-run it alone before treating it as real: it measures a wall-clock stall against a 100ms budget.

- [ ] **Step 3: Run the whole server suite**

Run: `cd /Users/skrug/PycharmProjects/yana-server && npx vitest run`
Expected: PASS

- [ ] **Step 4: Commit any fixes**

```bash
git commit -am "Fix fallout from the progress-monitoring rework"
```

(Skip if nothing needed fixing.)

---

### Task 13: Documentation

**Files:**
- Modify: `CLAUDE.md` (the **Networking**, **Actions**, **Key patterns** "Update vs. reload" and **Tests** sections)
- Modify: `/Users/skrug/PycharmProjects/yana-server/CLAUDE.md` if it enumerates `/api/v1` routes

- [ ] **Step 1: Update the client architecture notes**

In `CLAUDE.md`:

- **Networking:** add `JobStatus.swift` next to `RunStatus.swift`, note `RunStatusResponse` now carries the server's own `progress`, and that `JobStatusResponse` decodes `startedAt`/`finishedAt` as `String?` because `.iso8601` rejects the fractional seconds `toISOString()` writes.
- **Actions:** replace the `UpdateAndSync` description. Say that `ArticleActions` still only triggers, that `OperationMonitor` (`Yana/Services/OperationMonitor.swift`) owns everything after the ack, that the durable `jobs`/`runs` rows are the source of truth and SSE only moves numbers earlier, and that **no timeout is ever treated as success** — naming the bug this replaced, since that is the trap a future reader would otherwise re-introduce.
- **Key patterns → "Update vs. reload":** rewrite to describe polling `/api/v1/jobs/:id` and `/api/v1/runs/:id` to a terminal status, the percentage being shown verbatim, and `AppSettings.trackedOperations` surviving a relaunch so `OperationMonitor.resume()` picks the same wait back up.
- **Tests:** update the counts and name the new suites (`JobStatusTests`, `TrackedOperationTests`, `OperationMonitorTests`, `ReaderActionsTriggerTests`, `UpdateActivityTests`) and the removal of `UpdateAndSyncTests`. Get the real numbers from the Task 12 test run rather than estimating.

- [ ] **Step 2: Update the server notes**

If `/Users/skrug/PycharmProjects/yana-server/CLAUDE.md` lists the `/api/v1` surface, add `GET /api/v1/jobs/:id` and note that `progress` events are now published on every change, not only on terminal transitions.

- [ ] **Step 3: Commit both**

```bash
git commit -am "Document the progress-monitoring rework"
cd /Users/skrug/PycharmProjects/yana-server && git commit -am "Document the new job route and progress events"
```

---

## Self-review notes

Spec coverage checked section by section: `GET /api/v1/jobs/:id` (Task 2), run `progress` (Task 1), SSE progress events (Task 3), reload `progress()` calls (Task 4), `TrackedOperation` persistence (Task 6), `OperationMonitor` poll loop and no-timeout-is-success (Task 7), terminal follow-through with the visible-`Article` write and `preservingSummary` (Task 8), `resume()` at launch and foreground plus SSE before any POST (Task 9), outcome reporting moved off the triggering view (Task 10), spinner percentage on all three surfaces, `waitUntilIdle` removal and the refresh-control change (Task 11), server and client suites (Task 12), docs (Task 13).
