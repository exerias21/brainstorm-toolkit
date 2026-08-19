---
name: sdlc-lite
description: >
  The full /sdlc pipeline with a different ending: implement → evals → fix →
  validate, then HAND OFF the validated changes in
  your working tree for you to commit — it never commits, branches, pushes, or
  opens a PR. Use to run full SDLC discipline on work you want to review and
  commit yourself (e.g. onto an open PR's branch). Takes a plan file (like
  /sdlc), a task id, a task range (e.g. "1-5"), or an ad-hoc description. Only
  /sdlc touches git history; /sdlc-lite leaves that to you.
argument-hint: "<plan-file | task-id | task-range | description> [--resume] [--queue [N]]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# sdlc-lite — the /sdlc pipeline, leaving the commit to you (no git writes)

## When to use

| Skill | Input | Pipeline | Terminal action |
|---|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red→green only | commit only if you ask |
| `/sdlc-lite <plan \| task-id \| range \| desc>` | plan, task(s), or ask | **full** (sanity→implement→evals→validate) | **validated changes left in your working tree — you commit** |
| `/sdlc <plan-file>` | plan file | full | new branch → push → **PR** → `/review` |

`/sdlc-lite` and `/sdlc` run the **same stages** and reuse `/sdlc`'s templates
and state envelope verbatim. They differ in exactly one place: Stage 6. `/sdlc`
commits, pushes, and opens a PR; **`/sdlc-lite` does no git writes at all** — it
hands you a validated, ready-to-commit working tree. Only `/sdlc` touches git
history.

## Prerequisites

- You are on the branch the changes should land on (typically an open PR's
  branch). `/sdlc-lite` never switches branches and never commits.
- `.claude/project.json` optional; every key optional. Eval, validate, and
  flowsim stages skip silently when their config or a plan target is absent.
  **But** if `project.json` is absent while `project.json.example` is present,
  warn once at Stage 0 — every gated setting (`models.cap`, `pipeline.*`, test
  commands) is silently inert and the run will report `cap: none`.

## Output verbosity (default: quiet)

Run `/sdlc`'s "Output verbosity" section verbatim. **Default `quiet`** — one line
per stage (`<stage> · <verdict> · model: <tier> (cap: <cap|none>)`), one summary
table at Stage 7, no intermediate narration or echoed sub-agent output. Detail
already lives in the `stage-outputs/` sidecars. Always print regardless of
verbosity: the per-dispatch `model:` line, gate verdicts, PAUSE blocks, the
`Next:` seam line, and warnings. `pipeline.output.verbosity: "normal"` restores
narration; a missing `project.json` means `quiet`, by design.

## State envelope

Writes to `.claude/pipeline/<slug>/` — same path and sidecar shapes as `/sdlc`
(see `skills/sdlc/templates/state-schema.md`). Two additive fields:

- `run.json.pipeline = "sdlc-lite"` (distinguishes from `/sdlc` runs).
- Stage 6 sidecar is `handoff.json`
  (`{branch, files_changed[], committed: false, suggested_commit_msg}`)

**Resumption (`--resume`).** `/sdlc-lite <input> --resume` resumes a paused/failed
prior run for the resolved slug instead of restarting from scratch — it follows
`/sdlc`'s **Resumption** rules verbatim (read `run.json`; reject on a `plan_hash`
mismatch; skip stages whose sidecar shows `status: "pass"`; resume at the first
non-passing one; prose-path only). The only difference is the terminal stage
(hand-off, not PR). Resume keys on the **resolved slug**, so an ad-hoc-description
run must be resumed with the *same description text* (a reworded description
derives a different slug → "no prior run"); task-id / range / plan-file inputs
resolve to a stable slug and resume cleanly.
  instead of `pr-create.json`. No schema bump — both additive.

For a task **range**, `run.json.data.task_range` records the resolved ids.

---

## Stage 0 — Resolve input

Detect the argument shape:

1. **Plan file** — arg is a path ending `.md` that exists (e.g.
   `plans/my-feature.md`). Use it as the plan, exactly like `/sdlc` Stage 1.
   This is the primary path and the one that exercises the full pipeline
   (Stage 5's plan check has a plan to check against). **Also scan `TASKS.md`
   for `Active / Pending` rows that reference this plan** (by path or slug —
   e.g. `— plans/<slug>.md`, the form `/brainstorm` appends) and mark them
   `[~]`; Stage 6 closes them. A plan-file run that matches no such rows updates
   no `TASKS.md` — that's expected, not a miss.

2. **Task id** — arg matches `task-NNN` or a bare row number. Read that
   `TASKS.md` row and its linked `plans/tasks/task-N-<slug>.md`. The task
   file's `parent_plan:` frontmatter (if present) becomes the flowsim /
   Stage 5 plan target.

3. **Task range** — arg is `N-M`, `task-N..task-M`, or `tasks N-M`. Resolve
   every `Active / Pending` row in that inclusive range to its task file.
   Execute them as a batch (see Stage 6 range semantics). Record the resolved
   ids in `run.json.data.task_range`.

4. **Ad-hoc description** — anything else. Create a new `TASKS.md` row + task
   file using `/task`'s procedure (`skills/task/SKILL.md` Sections 1–2), then
   proceed. There's no plan, so Stage 5's plan check self-skips.

5. **Queue mode** — arg is `--queue [N]`. Select the work set from `TASKS.md` **by
   state + priority** (not a hand-typed range): the `Active / Pending` rows, top
   `N` (or `pipeline.loop.max_items`, default 5) by priority `P1 > P2 > P3`, an
   `[~]` in-progress row first. Then loop the pipeline over them with a re-scan and
   stop conditions — see **Queue mode** below (that re-scan is what makes it a loop,
   not a one-shot range).

Mark resolved rows `[~]` (in-progress). Derive `slug` per the algorithm in
`docs/CONVENTIONS.md`. Capture `base_commit` = `git rev-parse HEAD` and
initialize the state envelope at `.claude/pipeline/<slug>/` with
`pipeline: "sdlc-lite"`, `base_commit`, `status: "in_progress"`.
**Queue-mode exception:** the plan-file slug is shared by every row of a plan, so a
queued item derives a **distinct per-item slug** (`<plan-slug>-<row-id>`, or the
linked task-file slug) — see **Queue mode** — otherwise all its items collide on one
`.claude/pipeline/<slug>/` envelope.

**Continuity detection** (prompt, never auto) — the shared scan in
`skills/sdlc/templates/envelope-staleness.md`, same as `/sdlc`: **skip entirely when on the `main_branch`** (merges make every run an
ancestor there — pure noise). On a feature branch, take only the **single
most-recently-updated** run whose `base_commit` is an ancestor of HEAD, and
prompt **only** if it's non-terminal OR complete with HEAD advanced past its
recorded `commit_sha` (follow-up landed outside the pipeline). One prompt at
most, or none.

## Queue mode (`--queue`) — attended backlog loop

`--queue` runs the pipeline over the pending backlog and **re-scans between items**,
so work appended *during* the run (a `/status`-drafted fix, a brainstorm follow-up)
joins the loop — that re-scan is what makes it a loop rather than a fixed batch.
**No git writes** (it's `/sdlc-lite`): the whole loop leaves validated changes in
your tree for you to commit; it never runs `/sdlc` or opens a PR. The loop itself is
**prose-orchestrated** — each item runs the normal sdlc-lite pipeline (prose or, under
one pipeline run per item); the selection, re-scan, and stop conditions are here.

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
   breaks `--resume`'s plan-edit guard and `/status` + `/repo-health` staleness detection.**
   Plus `schema_version: 1`, `feature_slug`, `plan_file`, `base_commit`, `args`, and
   **canonical stage names** in `stage` / `stages_completed`
   (`implement`, `validate`, `handoff`, … — **never** phase labels like `phase-B-implement`
   or `phase-0`). Queue/phase bookkeeping is **additive in `data.*`**
   (`data.queue_mode: true`, `data.phase`, `data.tasks_done[]`) — never rename a canonical
   key (it is `feature_slug`/`plan_file`, not `slug`/`plan`) or overwrite `stage`.
3. **Stop conditions** (checked after each item — *every stop is a parked
   next-action, never a dead end*):
   - `stop_on: pause` (**always on**) — item ends `paused`/`failed` → write its
     `/status` hint to the seam and **park**. Never plow past a red run.
   - `stop_on: confirm` (**always on**) — the item's next action is `confirm: true`
     (would write git history) → park.
   - `max_items` (default `5`, or the `[N]` arg) — items consumed this invocation.
   - `max_consecutive_failures` (default `2`) — distinct-item failures before parking.
4. **Re-scan** `TASKS.md` for newly-appended rows and **go to 1**, until a stop
   condition parks the loop or the queue is empty.

**On park**, which envelope work you do depends on *why* it parked:
- **An item's own pipeline paused/failed** (`stop_on: pause`) → that **item's** envelope gets
  the full Stage 6 close-out: `status = "paused"` (**never leave it `in_progress`** — a parked
  run left `in_progress` is flagged stale by `/status`/`/repo-health` after ~24h) +
  `next_action = {cmd, confirm}` (the `/status` or `--resume`, L8). Then write the
  queue-resume sentinel below.
- **A queue-level stop** (`max_items` / `max_consecutive_failures` / a `confirm:true` action
  reached, with the current item already **complete**) → there is **no in-flight envelope to
  mark** (the last item's is already `complete`); the queue's own resume state is the
  `TASKS.md` rows + the sentinel. Just write the sentinel below.

**Then — ALWAYS, on every park — WRITE THE SENTINEL.** This is the step that keeps getting
skipped (agents write only `run.json.next_action` and stop, which leaves the loop dead). Be
exact about *why*: the `.claude/.next-action` **sentinel is the ONLY thing the Stop hook reads
and auto-surfaces**; `run.json.next_action` is a durable *fallback* that `/status` reads **on
demand** — it is **NOT** auto-surfaced. A park that sets only the envelope field is invisible
and cannot self-continue. Run these exact appends (dedup + multi-slot, `docs/SEAM.md`):

```sh
# (A) queue-resume line — ALWAYS when rows remain pending:
line='{"cmd":"/sdlc-lite <plan> --queue","source":"sdlc-lite","confirm":false}'
grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action
# (B) if it parked on a confirm:true action (a commit/rebuild the human must run FIRST),
#     ALSO append that action so the hook surfaces it:
line='{"cmd":"<the confirm action>","source":"sdlc-lite","confirm":true}'
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

## Stage 1.5 — Sanity check

**Read `skills/sdlc/templates/stage-1.5-sanity-check.md` now**, then run `/sdlc` Stage 1.5
(parallel focus agents on Claude; sequential on the
overlays). This is full SDLC discipline — it is **not** gated or optional. Honors
`models.sanity` and `agents.sanity_focuses` exactly as `/sdlc`
Stage 1.5 documents them — the default is 3 Haiku agents, and because the cap only
*lowers*, `sanity_check.model` is the only way to raise this stage.
For a task range, run it once over the combined set before the implement loop.

If the sanity check surfaces a blocker (plan references nonexistent files,
contradictory steps), stop and report rather than implementing on a bad premise.

## Stage 2 — Implement

**Delegation is mandatory. During this stage you do not call Write or Edit.** Dispatch the
implement agent(s) below and receive `git diff --numstat` back; the file bodies stay in the
agent's context, not yours. This is the single most expensive rule in the pipeline to break:
on an audited run the orchestrator made 183 Write/Edit calls against 8 dispatches, parking
~131k tokens of file content in its own context and driving the peak that forced five
context resets. If a change is too small to be worth an agent, it is too small for
`/sdlc-lite` — use `/task`.

**Read `skills/sdlc/templates/stage-2-implement.md` now**, before dispatching — not "reuse"
it, open it. A pointer that is never opened silently resolves to nothing, which is exactly
how the delegation rule above stopped reaching the model in the first place.

Then run `/sdlc` Stage 2, including its **live-code grounding** (follow
`skills/sdlc/templates/convention-grounding.md` — reuse existing patterns, treat
AGENTS.md/CLAUDE.md as stale-able hints, honor any `## Conventions & reuse` block
in the plan) and its **auto-gate**. Compute
`surfaces_touched` (from `skills/sdlc/templates/changed-files-gate.md` globs over
the planned files) and `task_count` (parse step count); **decompose iff**
`surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` (default `6`,
overridable via `.claude/project.json` `agents.decompose_min_tasks`) AND the
per-surface file sets are disjoint.

- **Single-agent (default):** dispatch one agent with `skills/sdlc/templates/stage-2-implement.md`,
  substitute `{feature_name}` and `{plan_content}`; **Sonnet by default** (Opus
  only on `--model opus`, per `skills/sdlc/templates/models.md`) on Claude,
  inline on Copilot/Codex. Writes `implement.json`, no decompose/converge sidecars.
  **Model cap applies** (inherited from `/sdlc` Stage 2): the implement/fix/lane
  tiers are lowered per `skills/sdlc/templates/models.md` — `--model <tier>`
  flag > `project.json models.cap` > default.
- **Decompose (large multi-surface plan):** run 2a/2b/2c per `/sdlc` Stage 2 —
  `skills/sdlc/templates/stage-2a-decompose.md` (Sonnet decomposer →
  `decompose.json`), `skills/sdlc/templates/stage-2b-dispatch.md` (one subagent
  per lane, sequential by `depends_on` → `implement-<lane>.json`), then
  `skills/sdlc/templates/stage-2c-converge.md` (orchestrator reconcile →
  `converge.json`). Set `run.json.data.stage2_decomposed` and
  `run.json.data.lanes`.

For a task **range**, the gate sees the combined file/step set. After
implementation, review `git diff --stat` and confirm expected files were
touched. Stop and report on any blocker.

## Stage 3 — Generate evals

Reuse `/sdlc` Stage 3 verbatim. **Skip silently if no `eval.runner` is
configured** — record `data.skipped_reason: "no eval.runner"`. Pure-docs work
degenerates cleanly into edit + commit.

## Stage 5 — Validate

Run `/sdlc` Stage 5 — now **one** stage: (1) `/test-check` over the
touched surfaces, then (2) **one agent** given the plan + diff that reports requirements
(met/partial/missing, each with a `file:line`) and flow (`MISMATCH`/`UNCLEAR`/`MISSING`)
separately. Skip axis (2) when there is no plan target, and say so. Route failures through the
shared fix loop (3-iteration budget). Writes one `validate.json`.

## Stage 5.7 — Adversarial review

Run `/sdlc` Stage 5.7/5.8 verbatim — same opt-in-only enablement (`--review-model <name>` flag or
`pipeline.review_fix.enabled: true`; `--no-review` always wins OFF; omitted/absent means
permanently OFF, no default-on flip), same auto-off gates (docs-only/no-surface diff self-skips
except in skill-repo mode, which adapts rather than skips), same **configurable** lens fan-out
(`agents.code_review_lenses`; defaults to all four —
`correctness`/`plan-alignment`/`config-env-docs`/`security` — and setting fewer cuts the stage's
cost roughly linearly, one reviewer call per lens), capped by `agents.code_review_max_lenses`
(default `4`; set `1` for a single-reviewer run, truncating in list order after circuit-breaker
demotion), same verify pass, optional second pass, and false-positive circuit breaker. Print the
resolved list before dispatching, per `/sdlc` Stage 5.7. Same cap caveat: every lens runs at the
**reviewer** model, which `models.cap` does not govern — warn when a cap is set and the reviewer
outranks it. Runs after Stage 5, before Stage 6 hand-off. Writes
`stage-outputs/review.json`; self-skips append `review` to `run.json.stages_skipped`.

## Stage 5.8 — Fix loop

Run `/sdlc` Stage 5.8 verbatim — same `auto_fixable` rubric, same `pipeline.review_fix.mode`
(interactive/auto/off) machinery, same independence enforcement and oscillation guard, same
cumulative `stage-outputs/review-fix.json`, and the same separate fix-loop budget
(`agents.code_review_max_fix_loops`, independent of the shared Stages 4/5/5.5/5.6 budget). One divergence,
matching `/sdlc-lite`'s existing warn-vs-block posture at Stage 6: a surviving HIGH-severity
confirmed finding does **not** block here — it is listed prominently in the Stage 7 handoff report
and the human decides whether to fix before committing, consistent with `/sdlc-lite`'s existing
warn-only secret-scan posture. **Post-fix validation still applies unconditionally**: if any fix
was applied this run, re-run the Stage 5 `validate` gate exactly once before Stage 6; a regression
there pauses the run for `/sdlc-lite` too (an objective break, not an adversarial opinion).

## Stage 6 — Hand off (no commit, no git writes)

`/sdlc-lite` runs the full pipeline and then **stops at the edge of git**. It
does not commit, stage-and-commit, branch, push, open a PR, or invoke
`/review`. The user reviews the validated working tree and commits it
themselves. (Want the commit + PR done for you? That's `/sdlc`.)

1. **Secret scan** the changed files using `/sdlc` Stage 6's procedure.
   **Warn-only**: surface findings (file:line) but never block. HIGH findings
   get a `⚠ HIGH:` prefix and a note that GitHub Push Protection on public
   remotes may reject a later push — worth scrubbing before you commit.

2. **Report the diff, don't commit it.** Show `git diff --stat`, the list of
   files changed, and a **suggested** commit message. Do NOT run `git add`,
   `git commit`, `git checkout -b`, `git push`, `gh pr create`, or `/review`.
   Leave the working tree exactly as the pipeline produced it.
   ```
   Suggested commit (run yourself when ready):
     git add <files>
     git commit -m "feat: <title>"
   ```
   **Range semantics**: process tasks in order; the changes from all tasks
   accumulate in the working tree. You decide how to slice commits (per task,
   or one bundle). Sanity-check (1.5) ran once up front; Stage 5's plan check and
   flowsim ran once at the end over the shared parent plan.

3. **Capture at loop-exit + seam** — run the shared protocol in
   `skills/gotcha/SKILL.md`. Auto-draft a gotcha **only** on an objective
   trigger — a test/eval/flowsim fix-loop that **failed-then-recovered**, or the
   user voicing surprise — route it through gotcha's dedup, and one-tap confirm.
   A clean run stays silent (no vibe-gating). If capture is **declined/deferred**,
   drop the seam sentinel instead — append ONE structured line, deduped by `cmd`
   (multi-slot: it now coexists with the pipeline handoff instead of racing it;
   see `docs/SEAM.md`):
   `line='{"cmd":"/gotcha <drafted text>","source":"sdlc-lite","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
   (never a bare `/gotcha`). On Codex (as a fallback until its `.codex/hooks.json` Stop hook is wired+trusted) also print `Next: /gotcha …`
   inline so the seam degrades gracefully.

4. **Close out**: mark `[x]` and move to `Done` **both** the rows resolved in
   Stage 0 **and** any `Active / Pending` `TASKS.md` row referencing this plan
   file/slug (e.g. rows `/brainstorm` appended); set `status: completed` in the
   task file(s). If a plan-file run genuinely matched no rows, **say so in the
   report** rather than silently skipping. The work is implemented and
   validated; only the commit is left to you.
   **Also leave re-entry rows** so the queue keeps the follow-up (`/sdlc-lite`
   opens no PR, so these are conditioned on delivery, not a PR number): when the
   changed-files gate flagged the **deploy-delta** surface, append
   `- [ ] (P1) rebuild <env> for <slug> (dependency change — rebuild, not restart) — plans/<slug>.md`;
   and a `- [ ] (P2) verify <slug> deployed — /repo-health`
   row closes the loop the same way `/sdlc` Stage 6 does.
   **Then print the manual-verification line** from `.claude/project.json` `stack.*`
   (all keys optional): the deploy-delta case prints `stack.rebuild` (a dependency
   changed, so a plain restart would run stale code), otherwise `stack.up`; append
   `stack.url` when set. This is a **printed suggestion, never auto-run** — the user
   asked for a validated tree, not a running one. When a needed key is absent, say
   which key would supply it rather than guessing a command:

   ```
   Verify: docker compose up -d --build --force-recreate   # stack.rebuild (dependency change)
   Open:   http://localhost:3000                            # stack.url
   ```

**State write**: `stage-outputs/handoff.json` =
`{branch, files_changed[], committed: false, suggested_commit_msg}`. **Always
set `run.json.status` to a terminal value** (`complete`, or `paused` if you
stopped mid-pipeline) before exiting — never leave it `in_progress`, or
`/repo-health` and `/status` will (correctly) flag it as a stale run. **Also set
`run.json.next_action = {cmd, confirm}` (L8)** when the run proposes a follow-up —
on pause the `/status` / `--resume` command, on complete the primary
re-entry (e.g. `/repo-health`) — so `/status` recovers the
handoff after the fire-once sentinel; omit when there's none. This holds
for **retro / validation-only runs** too (Stage 2 skipped because the code
already landed): advance `run.json.stage`/`stages_completed` as each validation
sidecar is written, add `implement` to `stages_skipped`, and close on a terminal
`status` — never leave a `parse`-stage envelope `in_progress` with sidecars
already on disk.

## Stage 7 — Report

Summarize: branch the changes are sitting on (uncommitted), files changed,
suggested commit message, eval pass/fail (or "skipped — no test surface"),
test-check summary, flowsim status (or "skipped — no plan target"), anything
left open. Make it explicit that **nothing was committed** — the next move is
yours.

## Gotchas

- **It does no git writes — ever.** No commit, no branch, no push, no PR, no
  `/review`. It hands you a validated working tree; you commit. Only `/sdlc`
  touches git history.
- **Stage 5's plan check runs whenever there's a plan to check** — pass a plan
  file (or a task with `parent_plan`) and they run unconditionally. They skip
  only when there is literally no plan target to validate against — never
  behind a separate opt-in flag or frontmatter knob.
- **Don't fork `/sdlc`'s templates.** If a stage needs different prompt copy,
  the work is probably a `/sdlc` job — re-invoke as `/sdlc`. Zero template
  duplication is the contract.
- **Range accumulates in the tree.** A range runs the pipeline over each task
  and leaves all changes uncommitted together; you choose how to slice the
  commits when you review.
