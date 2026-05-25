---
name: sdlc-lite
description: >
  The full /sdlc pipeline with a different ending: implement → evals → fix →
  validate → plan-validate → flowsim, then COMMIT ON THE CURRENT BRANCH —
  no new branch, no push, no PR. Use to stack vetted work onto an open PR's
  branch. Takes a plan file (like /sdlc), a task id, a task range (e.g.
  "1-5"), or an ad-hoc description. The only difference from /sdlc is the
  terminal action: commit-in-place vs. open-a-PR.
argument-hint: "<plan-file | task-id | task-range | description>"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# sdlc-lite — the /sdlc pipeline, committed on the current branch (no PR)

## When to use

| Skill | Input | Pipeline | Terminal action |
|---|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red→green only | green commit on current branch |
| `/sdlc-lite <plan \| task-id \| range \| desc>` | plan, task(s), or ask | **full** (sanity→implement→evals→fix→validate→plan-validate→flowsim) | **commit on current branch, no PR** |
| `/sdlc <plan-file>` | plan file | full | new branch → push → **PR** → `/review` |

`/sdlc-lite` and `/sdlc` run the **same stages** and reuse `/sdlc`'s templates
and state envelope verbatim. They differ in exactly one place: Stage 6. If you
want a PR, use `/sdlc`; if you want to stack onto the branch you're already on,
use `/sdlc-lite`.

## Prerequisites

- You are on the branch you want the commit(s) to land on (typically an open
  PR's branch). `/sdlc-lite` never switches branches.
- Working tree clean enough that this run's commits stage cleanly.
- `.claude/project.json` optional; every key optional. Eval, validate, and
  flowsim stages skip silently when their config or a plan target is absent.

## State envelope

Writes to `.claude/pipeline/<slug>/` — same path and sidecar shapes as `/sdlc`
(see `skills/sdlc/templates/state-schema.md`). Two additive fields:

- `run.json.pipeline = "sdlc-lite"` (distinguishes from `/sdlc` runs).
- Stage 6 sidecar is `commit.json` (`{branch, commits[], files_committed[]}`)
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
`docs/CONVENTIONS.md` and initialize the state envelope at
`.claude/pipeline/<slug>/`.

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

## Stage 6 — Commit on the current branch (no PR)

1. **Secret scan** the files about to be staged using `/sdlc` Stage 6's
   procedure. **Warn-only**: surface findings (file:line) but never block.
   HIGH findings get a `⚠ HIGH:` prefix and a note that GitHub Push Protection
   on public remotes may still reject a later push.

2. **Stage and commit on the current branch — no `git checkout -b`:**
   ```bash
   git add <specific files touched>
   git commit -m "feat: <title>

   Implemented via /sdlc-lite from <plan-or-task>.

   Co-Authored-By: <model> <noreply@anthropic.com>"
   ```
   **Range semantics**: one commit per task, in order — clean stacked history
   on the PR branch. Sanity-check (1.5) ran once up front; plan-validate and
   flowsim run once at the end over the shared parent plan.

3. **Do NOT** `git checkout -b`, `git push`, `gh pr create`, or `/review`.
   Stay on the current branch. (Want a PR? That's `/sdlc`.)

4. **Close out**: mark each resolved `TASKS.md` row `[x]`, move to `Done`, set
   `status: completed` in the task file(s).

**State write**: `stage-outputs/commit.json` =
`{branch, commits: [{sha, task_id?}], files_committed[]}`. Set
`run.json.status = "complete"`.

## Stage 7 — Report

Summarize: branch committed onto, commit SHA(s), task row(s) closed, eval
pass/fail (or "skipped — no test surface"), test-check summary, flowsim status
(or "skipped — no plan target"), anything left open.

## Gotchas

- **It never opens a PR or switches branches.** The whole point is to stack
  onto the branch you're already on. If you want a PR, use `/sdlc`.
- **flowsim/plan-validate run whenever there's a plan to check** — pass a plan
  file (or a task with `parent_plan`) and they run unconditionally. They skip
  only when there is literally no plan target to validate against — never
  behind a separate opt-in flag or frontmatter knob.
- **Don't fork `/sdlc`'s templates.** If a stage needs different prompt copy,
  the work is probably a `/sdlc` job — re-invoke as `/sdlc`. Zero template
  duplication is the contract.
- **Range = one commit per task.** Don't squash a range into a single commit;
  per-task commits keep the stacked PR reviewable.
