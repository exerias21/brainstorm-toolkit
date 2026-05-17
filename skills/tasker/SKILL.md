---
name: tasker
description: >
  Zero-flag middle skill: task-sized work with full /sdlc discipline minus the
  PR ceremony. Resolves or creates a TASKS.md row, implements, generates and
  runs evals, validates with /test-check, runs plan validators + flowsim when a
  parent plan is set, and commits on the current branch. No branch creation,
  no push, no PR. Use when a task is too big for /task's TDD inner loop but
  too small to justify the full /sdlc plan-to-PR pipeline.
argument-hint: "<description-or-task-id>"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Tasker — task-row work with full discipline, no PR

## When to use

| Skill | Input | Terminal action |
|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red-green → green commit on current branch |
| `/tasker <description-or-task-id>` | task-row work | implement → evals → validate → flowsim → commit on current branch |
| `/sdlc <plan-file>` | plan file | full pipeline → PR |

`/tasker` reuses `/sdlc`'s stage templates and state envelope verbatim —
**no new templates, no new state schema beyond two additive fields**. If a
stage diverges from `/sdlc`'s template, the right move is to fork the work
back to `/sdlc`, not to fork the template.

## Prerequisites

- Git working tree clean enough that this run's commit can be cleanly staged.
- `.claude/project.json` may exist; every key is optional. Eval and flowsim
  stages skip silently when their config is absent.

## State envelope

`/tasker` writes to `.claude/pipeline/<task-slug>/` — same path `/sdlc` uses,
same sidecar shapes from `skills/sdlc/templates/state-schema.md`. Two additive fields:

- `run.json.pipeline = "tasker"` (distinguishes from `/sdlc` runs).
- Stage 6 sidecar is `commit.json` (new shape) instead of `pr-create.json`:
  `{branch, commit_sha, files_committed[]}`.

No schema bump — both are additive.

## Stage 1 — Resolve task

If the argument matches an existing task ID (`task-NNN`) or a `TASKS.md`
row number, **read the existing row** and the linked
`plans/tasks/task-N-<slug>.md`. Mark the row `[~]` (in-progress).

Otherwise, **create a new row** using the same procedure `/task` uses
(see `skills/task/SKILL.md` Sections 1–2): determine the next task number,
slugify the description, append a row to `Active / Pending`, and write
`plans/tasks/task-<N>-<slug>.md` with the standard frontmatter. Mark `[~]`.

Derive `task_slug` from the task filename per the slug-derivation algorithm
in `docs/CONVENTIONS.md`. Initialize the state envelope at
`.claude/pipeline/<task_slug>/`.

## Stage 2 — Implement

Reuse `skills/sdlc/templates/stage-2-implement.md`. Substitute
`{feature_name}` with the task title and `{plan_content}` with the task
file's body. Use Opus for the implementation agent on Claude; on Copilot and
Codex, execute inline (same pattern the overlays use).

After implementation, review `git diff --stat` and confirm expected files
were touched. Stop and report on any blocker.

## Stage 3 — Generate evals

Reuse `/sdlc` Stage 3 verbatim — see `skills/sdlc/SKILL.md` Stage 3 for the
full procedure (Python pure functions → `tests/eval/`, fixture-based scripts
→ `<eval.features_dir>/<feature_slug>/`).

**Skip silently if no `eval.runner` is configured in `.claude/project.json`.**
Pure-docs tasks degenerate cleanly into a docs-edit + commit flow without
forcing a test surface — record `data.skipped_reason: "no eval.runner"` in
the sidecar and move on.

## Stage 4 — Eval + fix loop

Reuse `/sdlc` Stage 4 verbatim. Max 3 iterations (hardcoded). Skip when
Stage 3 was skipped.

If failures persist after 3 iterations, pause with the same message shape
`/sdlc` uses: report remaining failures and ask the user to fix manually,
then re-run `/tasker <task-id>`.

## Stage 5 — Validate

Reuse `/sdlc` Stage 5 verbatim — invoke `/test-check` and route any new
failures through the Stage 4 fix loop (counts toward the 3-iteration budget).

## Stage 5.5 — Plan validators (conditional)

**Only run this stage if the task file's frontmatter declares
`parent_plan: <path>`.** Otherwise skip silently and append
`plan-validate` to `run.json.stages_skipped`.

When `parent_plan` is set, reuse `skills/sdlc/templates/stage-5.5-validation.md`
with the parent plan as the validation target (substitute `{plan_file}` with
`parent_plan`, not the task file). Same gating table for which validators to
launch (api / ui / data / cross-module).

## Stage 5.6 — Flowsim (conditional)

**Only run this stage if `parent_plan` is set.** Otherwise skip silently and
append `flowsim` to `run.json.stages_skipped`.

When set, invoke `/flowsim <parent_plan>` and process results per `/sdlc`
Stage 5.6. Mismatches feed back through the Stage 4 fix loop (counts toward
the 3-iteration budget).

## Stage 6 — Commit

1. **Secret scan** the files about to be staged using the same procedure as
   `/sdlc` Stage 6 step 2 (gitleaks if available, regex-fallback otherwise).
   HIGH/CRITICAL → STOP. MEDIUM/LOW → warn and proceed.

2. **Stage and commit on the current branch** (no branch creation):
   ```bash
   git add <specific files touched>
   git commit -m "feat: <task title>

   Implemented via /tasker from <task-file>.

   Co-Authored-By: <model> <noreply@anthropic.com>"
   ```

3. **Do NOT** run `git push`, `gh pr create`, or `/review`. Stay on the
   current branch.

4. **Close out the task row**: mark `TASKS.md` row `[x]`, move it to the
   `Done` section, set `status: completed` in the task file's frontmatter.

**State write**: write `stage-outputs/commit.json` with
`{branch, commit_sha, files_committed[]}`. Set `run.json.status = "complete"`.

## Stage 7 — Report

Summarize:
- Task row closed
- Files committed and commit SHA
- Eval pass/fail counts (or "skipped — no test surface")
- Test-check summary
- Flowsim status (when run)
- Anything left open

## Gotchas

- **Don't fork templates.** If a stage genuinely needs different prompt copy
  than `/sdlc`, the task is probably big enough for `/sdlc` — kill the
  `/tasker` run and re-invoke as `/sdlc`. The whole point of this skill is
  zero template duplication.
- **No PR.** `/tasker` never branches, pushes, or opens a PR. If you want a
  PR, use `/sdlc`.
- **`parent_plan` is the only conditional knob.** Stages 5.5 and 5.6 gate on
  its presence in the task file frontmatter. Don't add other conditionals.
