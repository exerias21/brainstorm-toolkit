# Queue mode (`--queue`) — attended backlog loop

Loaded when `--queue` is passed, **or** when Stage 0's scope gate needs to park an oversized
plan's later phases (it calls only the **Park protocol** section below, not the loop). A
single-input run under its scope-gate threshold never opens this file. The loop runs the
normal pipeline once per item and adds selection, a re-scan, stop conditions and the park
protocol on top.

`--queue` runs the pipeline over the pending backlog and **re-scans between items**,
so work appended *during* the run (a `/sdlc-status`-drafted fix, a brainstorm follow-up)
joins the loop — that re-scan is what makes it a loop rather than a fixed batch.
**No git writes** (it's `/sdlc`): the whole loop leaves validated changes in
your tree for you to commit; it never opens a PR. The loop itself is
**prose-orchestrated** — one pipeline run per item; the selection, re-scan, and stop
conditions are here.

Loop (knobs under `project.json` `pipeline.loop.*`, all optional):

1. **Select** the next item — highest-priority `Active / Pending` row (`[~]` first),
   **excluding `_manual_` rows** (a human-only row is never selected into the loop).
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
   **Also write `data.tasks.resolved = ["<substring unique to this row>"]`** at envelope
   creation — a single-entry array, the same shape a task-id/range/ad-hoc run writes at its
   own Stage 0 (`skills/sdlc/SKILL.md` Stage 0). Use the row's linked
   `plans/tasks/task-N-<slug>.md` path when it has one, otherwise a unique substring of the
   row text itself. Stage 6's close-out (`stage-6-handoff.md`) reads this field to close
   **exactly** this item's row via `close-tasks.sh close --scope resolved` — omit it and
   close-out falls back to `--scope plan`, which sweeps in every sibling row sharing this
   item's `_plan:` key too.
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
  `next_action = {cmd, confirm}` (the `/sdlc-status` or `--resume`, L8). Then run the **Park
  protocol** below with `<resume-cmd>` = `/sdlc <plan> --queue`.
- **A queue-level stop** (`max_items` / `max_consecutive_failures` / a `confirm:true` action
  reached, with the current item already **complete**) → there is **no in-flight envelope to
  mark** (the last item's is already `complete`); the queue's own resume state is the
  `TASKS.md` rows + the sentinel. Just run the **Park protocol** below.

## Park protocol (shared — queue mode and the Stage 0 scope gate both call this)

Any `/sdlc` caller that stops before finishing its full work set — the queue loop between
items, or the Stage 0 scope gate leaving later phases for a follow-up run — parks the same
way: it never dead-ends, it writes a durable resume path. Substitute the caller's own resume
command for `<resume-cmd>` below (the queue loop uses `/sdlc <plan> --queue`; the scope gate
uses its recorded `run.json.data.scope_gate.resume`).

**ALWAYS, on every park — WRITE THE SENTINEL.** This is the step that keeps getting skipped
(agents write only `run.json.next_action` and stop, which leaves the loop dead). Be exact about
*why*: the `.claude/.next-action` **sentinel is the ONLY thing the Stop hook reads and
auto-surfaces**; `run.json.next_action` is a durable *fallback* that `/sdlc-status` reads **on
demand** — it is **NOT** auto-surfaced. A park that sets only the envelope field is invisible
and cannot self-continue. Run these exact appends (multi-slot, **deduped by `cmd`, not the
whole line** — the exact idiom `docs/SEAM.md` uses: `-F`/`-e` twice so a `cmd` containing regex
metacharacters, like a plan path's `.md`, is never misread as a pattern):

```sh
# (A) resume line — ALWAYS when work remains:
cmd='<resume-cmd>'
grep -qF -e "\"cmd\":\"$cmd\"" -e "\"cmd\": \"$cmd\"" .claude/.next-action 2>/dev/null \
  || echo "{\"cmd\":\"$cmd\",\"source\":\"sdlc\",\"confirm\":false}" >> .claude/.next-action
# (B) if it parked on a confirm:true action (a commit/rebuild the human must run FIRST),
#     ALSO append that action so the hook surfaces it:
cmd='<the confirm action>'
grep -qF -e "\"cmd\":\"$cmd\"" -e "\"cmd\": \"$cmd\"" .claude/.next-action 2>/dev/null \
  || echo "{\"cmd\":\"$cmd\",\"source\":\"sdlc\",\"confirm\":true}" >> .claude/.next-action
```

**Do NOT rely on `run.json.next_action` alone** — the sentinel `echo` above is mandatory on
every park. Then run the **no-hook nudge** (SEAM2): `grep -rlqs 'next-action'
.claude/settings.json ~/.claude/settings.json .github/hooks/ ~/.claude/plugins/
2>/dev/null` — if that finds nothing, the line is inert; tell the user to enable the
plugin or onboard, or the loop can't continue.

With the sentinel written, the Stop hook surfaces the resume — and with `pipeline.loop.auto_continue:
true`, **executes** it: the loop self-advances batch→batch hands-off until a `confirm:true`
action, a blocked/failed item, or the `pipeline.loop.max_hops` budget parks it. End with a
per-item results table (item → status → parked?).

**Long runs — context hygiene.** A many-hour `--queue`/auto-continue loop accumulates context in
the one orchestrator session (per-item pipeline work already runs in isolated subagents). The plugin
ships a reseed hook so the auto-compaction that fires on Claude/Codex stays lossless for the loop (it
re-points at the on-disk envelope/sentinel after a compact/clear); config knobs + the
fresh-process-per-item escalation are in `docs/LOOP-HYGIENE.md` (plugin repo).
