---
name: sdlc
description: >
  Run the full SDLC pipeline on a plan file, task id, task range (e.g. "1-5"), or
  an ad-hoc description: sanity-check → implement → evals → fix → validate →
  flowsim, then hand off the validated changes in your working tree for you to
  commit. Never commits, branches, pushes, or opens a PR — no git writes at all.
  Use when you want full SDLC discipline on work you will review and commit
  yourself, e.g. onto an open PR's branch. Use /task instead for a single small
  TDD fix with no plan.
argument-hint: "<plan-file | task-id | task-range | description> [--resume] [--queue [N]]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# sdlc — the full SDLC pipeline, leaving the commit to you (no git writes)

## When to use

| Skill | Input | Pipeline | Terminal action |
|---|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red→green only | commit only if you ask |
| `/sdlc <plan \| task-id \| range \| desc>` | plan, task(s), or ask | **full** (sanity→implement→evals→validate→flowsim) | **validated changes left in your working tree — you commit** |

**It does no git writes, ever** — no commit, branch, push, PR, or `/review`. It
hands you a validated, ready-to-commit working tree; the commit is yours. Stage
bodies live in `skills/sdlc/templates/` (a shared template tree, not a skill);
each stage below names the one it loads.

## Prerequisites

- You are on the branch the changes should land on (typically an open PR's
  branch). `/sdlc` never switches branches and never commits.
- `.claude/project.json` optional; every key optional. The eval stage and Stage 5's
  plan check + flowsim flow trace skip silently when their config or a plan target
  is absent.
  **But** if `project.json` is absent while `project.json.example` is present,
  warn once at Stage 0 — every gated setting (`models.cap`, `pipeline.*`, test
  commands) is silently inert and the run will report `cap: none`.

## Output verbosity (default: quiet)

**Read `skills/sdlc/templates/output-verbosity.md` now.** **Default `quiet`** — one line
per stage (`<stage> · <verdict> · model: <tier> (cap: <cap|none>)`), one summary
table at Stage 7, no intermediate narration or echoed sub-agent output. Detail
already lives in the `stage-outputs/` sidecars. Always print regardless of
verbosity: the per-dispatch `model:` line, gate verdicts, PAUSE blocks, the
`Next:` seam line, and warnings. `pipeline.output.verbosity: "normal"` restores
narration; a missing `project.json` means `quiet`, by design.

## State envelope

Writes to `.claude/pipeline/<slug>/` — the canonical envelope
(see `skills/sdlc/templates/state-schema.md`). Two additive fields:

- `run.json.pipeline = "sdlc"`.
- Stage 6 sidecar is `handoff.json`
  (`{branch, files_changed[], committed: false, suggested_commit_msg}`)

**Resumption (`--resume`).** `/sdlc <input> --resume` resumes a paused/failed
prior run for the resolved slug instead of restarting from scratch — **read
`skills/sdlc/templates/resumption.md` now** and follow it (read `run.json`; reject on a
`plan_hash` mismatch; skip stages whose sidecar shows `status: "pass"`; resume at the first
non-passing one). The only differences are the terminal stage (hand-off, not PR) and the
`handoff.json` sidecar it writes at Stage 6. Resume
keys on the **resolved slug**, so an ad-hoc-description run must be resumed with the *same
description text* (a reworded description derives a different slug → "no prior run"); task-id
/ range / plan-file inputs resolve to a stable slug and resume cleanly.

For a task **range**, `run.json.data.task_range` records the resolved ids.

---

## Stage 0 — Resolve input

Detect the argument shape:

1. **Plan file** — arg is a path ending `.md` that exists (e.g.
   `plans/my-feature.md`). Use it as the plan and parse it per Stage 0 below.
   This is the primary path and the one that exercises the full pipeline
   (Stage 5's plan check has a plan to check against). **Also scan `TASKS.md`
   for `Active / Pending` rows that reference this plan** (by path or slug —
   e.g. `— plans/<slug>.md`, the form `/brainstorm` appends) and mark them
   `[~]`; Stage 6 closes them. A plan-file run that matches no such rows updates
   no `TASKS.md` — that's expected, not a miss.

2. **Task id** — arg matches `task-NNN` or a bare row number. Read that
   `TASKS.md` row and its linked `plans/tasks/task-N-<slug>.md`. The task
   file's `parent_plan:` frontmatter (if present) becomes the flowsim / Stage 5
   plan target.

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
`pipeline: "sdlc"`, `base_commit`, `status: "in_progress"`.

**Then parse the plan.** Read the resolved plan/task file(s) fully and extract:
feature name/slug; implementation steps (numbered lists with file paths, or
checkbox rows); files to create or modify (file paths, a table of files, or each
linked task file's `files:` frontmatter); acceptance criteria ("expected",
"should", "must", "verify" language); cross-module touchpoints. A `TASKS.md`-style
checkbox list counts every `[ ]`/`[~]` row in `Active / Pending` as an
implementation step.

**Write `stage-outputs/parse.json`** with `data.feature_name`,
`data.files_to_change`, `data.implementation_step_count`,
`data.acceptance_criteria_count`, and append `parse` to
`run.json.stages_completed`. This is not bookkeeping: Stage 2's decompose gate
reads `data.files_to_change` and `data.implementation_step_count` and cannot run
without them.

**Native task mirror (Claude only; skip silently elsewhere).** Once the stage list for this run
is known, call `TaskCreate` once per stage that will actually run — the gates above have already
decided which those are, so a review-off run creates no `review` task. Mark each `in_progress` on
entry and `completed` on its sidecar write; a paused run leaves its stage `in_progress`, which is
the correct reading.

This is a **progress indicator, not state.** The durable record is `run.json` +
`stage-outputs/`; `TASKS.md` is the durable backlog. The native list is session-scoped and
Claude-only, so nothing may read it back — never let a decision depend on it. What it buys is a
live view of a long run *outside* the context window: the stage narration it replaces is re-read
by every later turn, the task list is not. That is why this is worth the calls.

**Skill-repo detection** (automatic, no flag): if `.claude-plugin/marketplace.json`
exists at repo root, the repo is itself a markdown-skill plugin — switch to the
substitutions in **Skill-repo mode** below for the rest of the run.

**Vendored-skill guard:** if `.claude-plugin/marketplace.json` is **absent** (an
ordinary consumer repo) but the plan's changed files target `.claude/skills/**`,
`.github/skills/**`, or `.agents/skills/**` — i.e. it edits *installed* skill
copies — **stop and report.** Those edits belong upstream in the canonical
toolkit repo and then get re-installed; shipping them through a consumer's
pipeline diverges the vendored copy from canonical.
**Queue-mode exception:** the plan-file slug is shared by every row of a plan, so a
queued item derives a **distinct per-item slug** (`<plan-slug>-<row-id>`, or the
linked task-file slug) — see **Queue mode** — otherwise all its items collide on one
`.claude/pipeline/<slug>/` envelope.

**Continuity detection** (prompt, never auto) — the shared scan in
`skills/sdlc/templates/envelope-staleness.md`: **skip entirely when on the
`main_branch`** (merges make every run an ancestor there — pure noise). On a
feature branch, take only the **single most-recently-updated** run whose
`base_commit` is an ancestor of HEAD, and prompt **only** if it's non-terminal OR
complete with HEAD advanced past that `base_commit` (follow-up landed outside the
pipeline). One prompt at most, or none.

## Queue mode (`--queue`) — attended backlog loop

Only when the argument is `--queue [N]`. **Resolve that first** — on any other input, skip this
section entirely and go to Stage 1.5 without opening the template.

When it *is* `--queue`, **read `skills/sdlc/templates/queue-mode.md` now** and run it. It carries
the selection rule (highest-priority `Active / Pending` row, `[~]` first), the per-item envelope
and its distinct slug, the four stop conditions, the `TASKS.md` re-scan that makes it a loop
rather than a batch, the park protocol and its **mandatory** `.claude/.next-action` sentinel, and
the long-run context-hygiene note.
## Stage 1.5 — Sanity check

**Read `skills/sdlc/templates/stage-1.5-sanity-check.md` now** and run it (parallel focus
agents on Claude; sequential on the overlays). It carries the orchestration and the per-focus
prompts. This is full SDLC discipline — it is **not** gated or optional. The default is 3 Haiku
agents; `models.sanity` and `agents.sanity_focuses` tune it, and because the cap only *lowers*,
`sanity_check.model` is the only way to raise this stage.
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
`/sdlc` — use `/task`.

**Read `skills/sdlc/templates/stage-2-implement.md` now**, before dispatching — not "reuse"
it, open it. A pointer that is never opened silently resolves to nothing, which is exactly
how the delegation rule above stopped reaching the model in the first place.

Then apply the **live-code grounding** (follow `skills/sdlc/templates/convention-grounding.md`
— reuse existing patterns, treat AGENTS.md/CLAUDE.md as stale-able hints, honor any
`## Conventions & reuse` block in the plan) and the **auto-gate**: **read
`skills/sdlc/templates/stage-2-gate.md` now** — it computes `surfaces_touched` (via
`skills/sdlc/templates/changed-files-gate.md`) and `task_count`, and **decomposes iff**
`surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` (default `6`, overridable via
`.claude/project.json` `agents.decompose_min_tasks`) AND the per-surface file sets are
disjoint.

- **Single-agent (default):** dispatch one agent with `skills/sdlc/templates/stage-2-implement.md`,
  substitute `{feature_name}` and `{plan_content}`; **Sonnet by default** (Opus
  only on `--model opus`, per `skills/sdlc/templates/models.md`) on Claude,
  inline on Copilot/Codex. Writes `implement.json`, no decompose/converge sidecars.
  **Model cap applies**: the implement/fix/lane
  tiers are lowered per `skills/sdlc/templates/models.md` — `--model <tier>`
  flag > `project.json models.cap` > default.
- **Decompose (large multi-surface plan):** run 2a/2b/2c —
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

**Read `skills/sdlc/templates/stage-3-evals.md` now** and run it. **Skip silently if no `eval.runner` is
configured** — record `data.skipped_reason: "no eval.runner"`. Pure-docs work
degenerates cleanly into edit + commit.

## Stage 5 — Validate

**Read `skills/sdlc/templates/stage-5-validate.md` now** and run it — one stage: (1) dispatch
the **`test-runner`** agent (Haiku, structured pass/fail only — never run the suites inline;
test output is the biggest single source of context bloat) over the touched surfaces, then
(2) **one agent** given the plan + diff that reports requirements (met/partial/missing, each
with a `file:line`) and flow (`MISMATCH`/`UNCLEAR`/`MISSING`) separately. Skip axis (2) when
there is no plan target, and say so.

**The flow axis gates only when witnessed** (per the template): with no test evidence from step
1, flow findings are reported as **advisory** — they cannot fail the stage or open the fix loop.
The requirements axis gates unconditionally; it is the pipeline's only detector for a plan step
that was silently never implemented.

Route failures through the shared fix loop (**read `skills/sdlc/templates/fix-loop.md`** at the
first failure; 3-iteration budget). Writes one `validate.json`.

## Stage 5.7 — Adversarial review

**Opt-in, permanently OFF by default — resolve the gate before loading anything.** Same
opt-in-only enablement (`--review-model <name>` flag or
`pipeline.review_fix.enabled: true`; `--no-review` always wins OFF; omitted/absent means
permanently OFF, no default-on flip), same auto-off gates (docs-only/no-surface diff self-skips
except in skill-repo mode, which adapts rather than skips), same **configurable** lens fan-out
(`agents.code_review_lenses`; defaults to all four —
`correctness`/`plan-alignment`/`config-env-docs`/`security` — and setting fewer cuts the stage's
cost roughly linearly, one reviewer call per lens), capped by `agents.code_review_max_lenses`
(default `4`; set `1` for a single-reviewer run, truncating in list order after circuit-breaker
demotion), same verify pass, optional second pass, and false-positive circuit breaker. Print the
resolved list before dispatching, per the template. Same cap caveat: every lens runs at the
**reviewer** model, which `models.cap` does not govern — warn when a cap is set and the reviewer
outranks it. Runs after Stage 5, before Stage 6 hand-off. Writes
`stage-outputs/review.json`; self-skips append `review` to `run.json.stages_skipped`.

When (and only when) the stage is enabled, **read
`skills/sdlc/templates/stage-5.7-review-fix.md` now** and run it. When it is OFF, do not load
that file — append `review` to `run.json.stages_skipped` and go to Stage 6.

## Stage 5.8 — Fix loop

Specified in that same template — same `auto_fixable` rubric, same `pipeline.review_fix.mode`
(interactive/auto/off) machinery, same independence enforcement and oscillation guard, same
cumulative `stage-outputs/review-fix.json`, and the same separate fix-loop budget
(`agents.code_review_max_fix_loops`, independent of Stage 5's shared budget). One divergence,
matching `/sdlc`'s existing warn-vs-block posture at Stage 6: a surviving HIGH-severity
confirmed finding does **not** block here — it is listed prominently in the Stage 7 handoff report
and the human decides whether to fix before committing, consistent with `/sdlc`'s existing
warn-only secret-scan posture. **Post-fix validation still applies unconditionally**: if any fix
was applied this run, re-run the Stage 5 `validate` gate exactly once before Stage 6; a regression
there pauses the run for `/sdlc` too (an objective break, not an adversarial opinion).

## Stage 6 — Hand off (no commit, no git writes)

`/sdlc` runs the full pipeline and then **stops at the edge of git**. It
does not commit, stage-and-commit, branch, push, open a PR, or invoke
`/review`. The user reviews the validated working tree and commits it
themselves.

1. **Secret scan** the changed files — **read `skills/sdlc/templates/secret-scan.md` now**
   and run it. **Warn-only**: surface findings (file:line) but never block. HIGH findings
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
   flowsim trace ran once at the end over the shared parent plan.

3. **Capture at loop-exit + seam** — run the shared protocol in
   `skills/gotcha/SKILL.md`. Auto-draft a gotcha **only** on an objective
   trigger — a test/eval/flowsim fix-loop that **failed-then-recovered**, or the
   user voicing surprise — route it through gotcha's dedup, and one-tap confirm.
   A clean run stays silent (no vibe-gating). If capture is **declined/deferred**,
   drop the seam sentinel instead — append ONE structured line, deduped by `cmd`
   (multi-slot: it now coexists with the pipeline handoff instead of racing it;
   see `docs/SEAM.md`):
   `line='{"cmd":"/gotcha <drafted text>","source":"sdlc","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
   (never a bare `/gotcha`). On Codex (as a fallback until its `.codex/hooks.json` Stop hook is wired+trusted) also print `Next: /gotcha …`
   inline so the seam degrades gracefully.

4. **Close out**: mark `[x]` and move to `Done` **both** the rows resolved in
   Stage 0 **and** any `Active / Pending` `TASKS.md` row referencing this plan
   file/slug (e.g. rows `/brainstorm` appended); set `status: completed` in the
   task file(s). If a plan-file run genuinely matched no rows, **say so in the
   report** rather than silently skipping. The work is implemented and
   validated; only the commit is left to you.
   **Also leave re-entry rows** so the queue keeps the follow-up (`/sdlc`
   opens no PR, so these are conditioned on delivery, not a PR number): when the
   changed-files gate flagged the **deploy-delta** surface, append
   `- [ ] (P1) rebuild <env> for <slug> (dependency change — rebuild, not restart) — plans/<slug>.md`;
   and a `- [ ] (P2) verify <slug> deployed — /repo-health`
   row closes the loop.
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
`/repo-health` and `/sdlc-status` will (correctly) flag it as a stale run. **Also set
`run.json.next_action = {cmd, confirm}` (L8)** when the run proposes a follow-up —
on pause the `/sdlc-status` / `--resume` command, on complete the primary
re-entry (e.g. `/repo-health`) — so `/sdlc-status` recovers the
handoff after the fire-once sentinel; omit when there's none. This holds
for **retro / validation-only runs** too (Stage 2 skipped because the code
already landed): advance `run.json.stage`/`stages_completed` as each validation
sidecar is written, add `implement` to `stages_skipped`, and close on a terminal
`status` — never leave a `parse`-stage envelope `in_progress` with sidecars
already on disk.

## Stage 7 — Report

Summarize: branch the changes are sitting on (uncommitted), files changed,
suggested commit message, eval pass/fail (or "skipped — no test surface"),
test-check summary, the Stage 5 plan check — requirements verdict plus the flowsim
flow trace and whether it was witnessed or advisory (or "skipped — no plan target")
— and anything left open. Make it explicit that **nothing was committed** — the next move is
yours.

## Skill-repo mode (auto-detected)

Active when `.claude-plugin/marketplace.json` exists at repo root (detected at
Stage 0). The standard pipeline is shaped for "code-with-tests"; a skill repo has
no test surface, so the eval-driven stages are inapplicable. Three stages change;
every other stage runs unmodified.

| Stage | Skill-repo behavior |
|---|---|
| Stage 3 — Generate evals | **skip** (no test surface) — append `generate-evals` to `run.json.stages_skipped` |
| Stage 5 — Validate | **substitute** with `skills/sdlc/templates/stage-5-skill-repo.md` (HARD: validator, marketplace registration, template-reference resolution, setup.sh dry install; SOFT: line-count ceiling, README skills-table drift, overlay parity). Writes `validate.json` with `data.mode = "skill-repo"` |
| Stage 5.7 — Adversarial review | **adapt, never self-skip** — a docs-only diff is the code surface here. Correctness and plan-alignment apply equally to prose; `security` applies its skill-repo shell-injection check; `config-env-docs` repoints to the frontmatter / marketplace / template-reference checks in `stage-5-skill-repo.md` |

## Safety rules

- **Stop on ambiguity** — if the plan has unclear steps, pause and ask.
- **Stop on repeated failures** — if a fix loop can't resolve within its budget,
  report rather than grinding.
- **Don't fix pre-existing failures** — only fix what this run introduced.
  Stage 5's `preexisting[]` is reported, never gated on.
- **Autonomy overrides interactive output styles** — this is an autonomous
  pipeline. If an interactive output style (a "learning"/contribution-seeking
  mode) is active, the explicit invocation wins: run autonomously, don't pause
  to solicit user-authored code mid-pipeline.

## Gotchas

- **It does no git writes — ever.** No commit, no branch, no push, no PR, no
  `/review`. It hands you a validated working tree; you commit.
- **Stage 5's plan check runs whenever there's a plan to check** — pass a plan
  file (or a task with `parent_plan`) and they run unconditionally. They skip
  only when there is literally no plan target to validate against — never
  behind a separate opt-in flag or frontmatter knob.
- **Don't fork the shared templates.** Stage bodies live once in
  `skills/sdlc/templates/`; edit the template, never copy it into this file.
  Zero template duplication is the contract.
- **Range accumulates in the tree.** A range runs the pipeline over each task
  and leaves all changes uncommitted together; you choose how to slice the
  commits when you review.
