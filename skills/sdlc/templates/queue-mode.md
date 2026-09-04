# Queue mode (`--queue`) — attended backlog loop

Loaded **only when `--queue` is passed.** A single-input run never opens this file; resolve the
flag first. The loop runs the normal pipeline once per item and adds selection, a re-scan, stop
conditions and the park protocol on top.

`--queue` runs the pipeline over the pending backlog and **re-scans between items**,
so work appended *during* the run (a `/sdlc-status`-drafted fix, a brainstorm follow-up)
joins the loop — that re-scan is what makes it a loop rather than a fixed batch.
**No git writes** (it's `/sdlc`): the whole loop leaves validated changes in
your tree for you to commit; it never opens a PR. The loop itself is
**prose-orchestrated** — one pipeline run per item; the selection, re-scan, and stop
conditions are here.

Loop (knobs under `project.json` `pipeline.loop.*`, all optional):

1. **Select** the next item — highest-priority `Active / Pending` row (`[~]` first).
   Mark it `[~]`.
2. **Run** the full pipeline (Stages 1.5–6) for that item as a single-item run — its
   own **canonical envelope** and its own shared 3-iteration fix budget. **Each item's
   `feature_slug` is distinct per row** — `<plan-slug>-<row-id>` (e.g. row `Q1` of
   `plans/verify-queue.md` → `verify-queue-q1`), **never the bare plan slug**: every row of
   one plan shares that plan's slug, so per-item envelopes keyed on it would all collide in
   one `.claude/pipeline/<plan-slug>/` dir (the dogfood showed exactly this — one envelope
   overwritten per item). A row with a linked `plans/tasks/task-N-<slug>.md` uses that task
   slug instead. The envelope is canonical per `skills/sdlc/templates/state-schema.md` —
   **all** required keys, including the three that keep getting dropped because they need
   *computing* (write them, don't skip):
   `plan_hash: "sha256:$(sha256sum <plan-file> | cut -d' ' -f1)"`,
   `started_at` / `updated_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"` (refresh `updated_at` on
   every stage transition). **Omitting `plan_hash` / `started_at` / `updated_at` silently
   breaks `--resume`'s plan-edit guard and `/sdlc-status` + `/repo-health` staleness detection.**
   Plus `schema_version: 1`, `feature_slug`, `plan_file`, `base_commit`, `args`, and
   **canonical stage names** in `stage` / `stages_completed`
   (`implement`, `validate`, `handoff`, … — **never** phase labels like `phase-B-implement`
   or `phase-0`). Queue/phase bookkeeping is **additive in `data.*`**
   (`data.queue_mode: true`, `data.phase`, `data.tasks_done[]`) — never rename a canonical
   key (it is `feature_slug`/`plan_file`, not `slug`/`plan`) or overwrite `stage`.
3. **Stop conditions** (checked after each item — *every stop is a parked
   next-action, never a dead end*):
   - `stop_on: pause` (**always on**) — item ends `paused`/`failed` → write its
     `/sdlc-status` hint to the seam and **park**. Never plow past a red run.
   - `stop_on: confirm` (**always on**) — the item's next action is `confirm: true`
     (would write git history) → park.
   - `max_items` (default `5`, or the `[N]` arg) — items consumed this invocation.
   - `max_consecutive_failures` (default `2`) — distinct-item failures before parking.
4. **Re-scan** `TASKS.md` for newly-appended rows and **go to 1**, until a stop
   condition parks the loop or the queue is empty.

**On park**, which envelope work you do depends on *why* it parked:
- **An item's own pipeline paused/failed** (`stop_on: pause`) → that **item's** envelope gets
  the full Stage 6 close-out: `status = "paused"` (**never leave it `in_progress`** — a parked
  run left `in_progress` is flagged stale by `/sdlc-status`/`/repo-health` after ~24h) +
  `next_action = {cmd, confirm}` (the `/sdlc-status` or `--resume`, L8). Then write the
  queue-resume sentinel below.
- **A queue-level stop** (`max_items` / `max_consecutive_failures` / a `confirm:true` action
  reached, with the current item already **complete**) → there is **no in-flight envelope to
  mark** (the last item's is already `complete`); the queue's own resume state is the
  `TASKS.md` rows + the sentinel. Just write the sentinel below.

**Then — ALWAYS, on every park — WRITE THE SENTINEL.** This is the step that keeps getting
skipped (agents write only `run.json.next_action` and stop, which leaves the loop dead). Be
exact about *why*: the `.claude/.next-action` **sentinel is the ONLY thing the Stop hook reads
and auto-surfaces**; `run.json.next_action` is a durable *fallback* that `/sdlc-status` reads **on
demand** — it is **NOT** auto-surfaced. A park that sets only the envelope field is invisible
and cannot self-continue. Run these exact appends (dedup + multi-slot, `docs/SEAM.md`):

```sh
# (A) queue-resume line — ALWAYS when rows remain pending:
line='{"cmd":"/sdlc <plan> --queue","source":"sdlc","confirm":false}'
grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action
# (B) if it parked on a confirm:true action (a commit/rebuild the human must run FIRST),
#     ALSO append that action so the hook surfaces it:
line='{"cmd":"<the confirm action>","source":"sdlc","confirm":true}'
grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action
```

**Do NOT rely on `run.json.next_action` alone** — the sentinel `echo` above is mandatory on
every park. Then run the **no-hook nudge** (`docs/SEAM.md` SEAM2): if no Stop hook is wired,
the line is inert — tell the user to enable the plugin or onboard, or the loop can't continue.

With the sentinel written, the Stop hook surfaces the resume — and with `pipeline.auto_continue:
true`, **executes** it: the loop self-advances batch→batch hands-off until a `confirm:true`
action, a blocked/failed item, or the `pipeline.loop.max_hops` budget parks it. End with a
per-item results table (item → status → parked?).

**Long runs — context hygiene.** A many-hour `--queue`/auto-continue loop accumulates context in
the one orchestrator session (per-item pipeline work already runs in isolated subagents). The plugin
ships a reseed hook so the auto-compaction that fires on Claude/Codex stays lossless for the loop (it
re-points at the on-disk envelope/sentinel after a compact/clear); config knobs + the
fresh-process-per-item escalation are in `docs/LOOP-HYGIENE.md` (plugin repo).
