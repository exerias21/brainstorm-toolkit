---
name: sdlc-lite
description: >
  The full /sdlc pipeline with a different ending: implement → evals → fix →
  validate → plan-validate → flowsim, then HAND OFF the validated changes in
  your working tree for you to commit — it never commits, branches, pushes, or
  opens a PR. Use to run full SDLC discipline on work you want to review and
  commit yourself (e.g. onto an open PR's branch). Takes a plan file (like
  /sdlc), a task id, a task range (e.g. "1-5"), or an ad-hoc description. Only
  /sdlc touches git history; /sdlc-lite leaves that to you.
argument-hint: "<plan-file | task-id | task-range | description>"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# sdlc-lite — the /sdlc pipeline, leaving the commit to you (no git writes)

## When to use

| Skill | Input | Pipeline | Terminal action |
|---|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red→green only | commit only if you ask |
| `/sdlc-lite <plan \| task-id \| range \| desc>` | plan, task(s), or ask | **full** (sanity→implement→evals→fix→validate→plan-validate→flowsim) | **validated changes left in your working tree — you commit** |
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

## State envelope

Writes to `.claude/pipeline/<slug>/` — same path and sidecar shapes as `/sdlc`
(see `skills/sdlc/templates/state-schema.md`). Two additive fields:

- `run.json.pipeline = "sdlc-lite"` (distinguishes from `/sdlc` runs).
- Stage 6 sidecar is `handoff.json`
  (`{branch, files_changed[], committed: false, suggested_commit_msg}`)
  instead of `pr-create.json`. No schema bump — both additive.

For a task **range**, `run.json.data.task_range` records the resolved ids.

---

## Stage 0 — Resolve input

Detect the argument shape:

1. **Plan file** — arg is a path ending `.md` that exists (e.g.
   `plans/my-feature.md`). Use it as the plan, exactly like `/sdlc` Stage 1.
   This is the primary path and the one that exercises the full pipeline
   (flowsim/plan-validate have a plan to check against).

2. **Task id** — arg matches `task-NNN` or a bare row number. Read that
   `TASKS.md` row and its linked `plans/tasks/task-N-<slug>.md`. The task
   file's `parent_plan:` frontmatter (if present) becomes the flowsim /
   plan-validate target.

3. **Task range** — arg is `N-M`, `task-N..task-M`, or `tasks N-M`. Resolve
   every `Active / Pending` row in that inclusive range to its task file.
   Execute them as a batch (see Stage 6 range semantics). Record the resolved
   ids in `run.json.data.task_range`.

4. **Ad-hoc description** — anything else. Create a new `TASKS.md` row + task
   file using `/task`'s procedure (`skills/task/SKILL.md` Sections 1–2), then
   proceed. There's no plan, so plan-validate/flowsim self-skip (Stage 5.5/5.6).

Mark resolved rows `[~]` (in-progress). Derive `slug` per the algorithm in
`docs/CONVENTIONS.md`. Capture `base_commit` = `git rev-parse HEAD` and
initialize the state envelope at `.claude/pipeline/<slug>/` with
`pipeline: "sdlc-lite"`, `base_commit`, `status: "in_progress"`.

**Continuity detection** (prompt, never auto) — same as `/sdlc`: glob
`.claude/pipeline/*/run.json`; if a prior `sdlc`/`sdlc-lite` run's
`base_commit` is an ancestor of HEAD (`git merge-base --is-ancestor`), surface
it ("this branch ran /<pipeline> at <sha>; continue that flow or start fresh?")
rather than silently starting a parallel run.

## Stage 1.5 — Sanity check

Run `/sdlc` Stage 1.5 verbatim (the 3-agent pre-flight on Claude; sequential on
the overlays). This is full SDLC discipline — it is **not** gated or optional.
For a task range, run it once over the combined set before the implement loop.

If the sanity check surfaces a blocker (plan references nonexistent files,
contradictory steps), stop and report rather than implementing on a bad premise.

## Stage 2 — Implement

Reuse `skills/sdlc/templates/stage-2-implement.md`. Substitute `{feature_name}`
and `{plan_content}` from the resolved plan or task body. Opus implementation
agent on Claude; inline on Copilot/Codex.

After implementation, review `git diff --stat` and confirm expected files were
touched. Stop and report on any blocker.

## Stage 3 — Generate evals

Reuse `/sdlc` Stage 3 verbatim. **Skip silently if no `eval.runner` is
configured** — record `data.skipped_reason: "no eval.runner"`. Pure-docs work
degenerates cleanly into edit + commit.

## Stage 4 — Eval + fix loop

Reuse `/sdlc` Stage 4 verbatim. Max 3 iterations (hardcoded). Skip when Stage 3
was skipped. If failures persist after 3 iterations, pause with `/sdlc`'s
message shape and ask the user to fix manually, then re-run.

## Stage 5 — Validate

Reuse `/sdlc` Stage 5 verbatim — invoke `/test-check`; route new failures
through the Stage 4 fix loop (counts toward the 3-iteration budget).

## Stage 5.5 — Plan requirements validation

Run `/sdlc` Stage 5.5 against the **plan target**:
- plan-file input → the plan file itself,
- task input with `parent_plan` → that parent plan.

If there is **no plan target** (ad-hoc description, or a task with no
`parent_plan`), skip and append `plan-validate` to `run.json.stages_skipped`.
This is a "nothing to validate against" skip, not an arbitrary gate — give it a
plan and it always runs.

## Stage 5.6 — Flowsim

Same gating as 5.5: run `/flowsim <plan-target>` whenever a plan target exists;
skip with a note when none does. Mismatches feed the Stage 4 fix loop (counts
toward the budget). Process results per `/sdlc` Stage 5.6.

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
   or one bundle). Sanity-check (1.5) ran once up front; plan-validate and
   flowsim ran once at the end over the shared parent plan.

3. **Capture gotchas (knowledge sink)**: if the run hit a non-obvious trap,
   prompt to append it to `GOTCHAS.md` via `/gotcha` — the durable project
   file is the sink, not model memory. One nudge, skip if nothing came up.

4. **Close out**: mark each resolved `TASKS.md` row `[x]`, move to `Done`, set
   `status: completed` in the task file(s) — the work is implemented and
   validated; only the commit is left to you.

**State write**: `stage-outputs/handoff.json` =
`{branch, files_changed[], committed: false, suggested_commit_msg}`. **Always
set `run.json.status` to a terminal value** (`complete`, or `paused` if you
stopped mid-pipeline) before exiting — never leave it `in_progress`, or
`/repo-health` and `/status` will (correctly) flag it as a stale run.

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
- **flowsim/plan-validate run whenever there's a plan to check** — pass a plan
  file (or a task with `parent_plan`) and they run unconditionally. They skip
  only when there is literally no plan target to validate against — never
  behind a separate opt-in flag or frontmatter knob.
- **Don't fork `/sdlc`'s templates.** If a stage needs different prompt copy,
  the work is probably a `/sdlc` job — re-invoke as `/sdlc`. Zero template
  duplication is the contract.
- **Range accumulates in the tree.** A range runs the pipeline over each task
  and leaves all changes uncommitted together; you choose how to slice the
  commits when you review.
