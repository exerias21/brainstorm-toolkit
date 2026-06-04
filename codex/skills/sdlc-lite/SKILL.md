---
name: sdlc-lite
description: >
  Sequential full-pipeline-minus-git skill for Codex CLI. Takes a plan file, a
  task id, a task range (e.g. "1-5"), or an ad-hoc description; runs
  implement → evals → validate → plan-validate → flowsim; then hands off the
  validated changes for you to commit. No commit, no branch, no push, no PR.
  Codex-optimized overlay of canonical /sdlc-lite — every stage runs inline
  (no parallel sub-agents, no Plan mode). Same stages as /sdlc; only /sdlc
  touches git.
argument-hint: "<plan-file | task-id | task-range | description>"
metadata:
  brainstorm-toolkit-applies-to: codex
disable-model-invocation: true
---

# sdlc-lite (Codex Edition — Sequential)

Sequential version of `/sdlc-lite`. Canonical `/sdlc-lite` uses parallel agent
dispatch for the sanity-check and Stage 5.5 validators on Claude; this overlay
runs every stage inline. Codex CLI's 2026 Agent Skills spec, like Copilot's,
doesn't yet support parallel sub-agent dispatch. This overlay tracks the Copilot
one closely; tune independently if Codex behavior diverges. Same stages as
`/sdlc`; the only difference is Stage 6 — `/sdlc-lite` does **no git writes**
(hands you a validated tree to commit), while `/sdlc` commits + opens a PR.

## When to use

| Skill | Input | Terminal action |
|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red-green → commit only if you ask |
| `/sdlc-lite <plan \| task-id \| range \| desc>` | plan, task(s), or ask | full pipeline → validated changes left for you to commit |
| `/sdlc <plan-file>` | plan file | full pipeline → commit + PR |

Reuses `/sdlc`'s stage templates and state envelope verbatim — no new
templates, no new schema beyond `run.json.pipeline = "sdlc-lite"` and a
`handoff.json` sidecar at Stage 6.

## Prerequisites

- You are on the branch the changes should land on. This skill never switches
  branches and never commits.
- `.claude/project.json` optional. Eval / validate / flowsim skip silently when
  their config or a plan target is absent.

## Stage 0 — Resolve input

- **Plan file** (path ending `.md` that exists) → use as the plan, like `/sdlc`.
- **Task id** (`task-NNN` or a row number) → read that row + linked task file;
  its `parent_plan:` becomes the flowsim/plan-validate target.
- **Task range** (`N-M`, `task-N..task-M`, `tasks N-M`) → resolve every
  `Active / Pending` row in range; execute as a batch (one commit per task).
- **Ad-hoc description** → create a new row + task file via `/task`'s procedure.

Mark resolved rows `[~]`. Derive `slug` per `docs/CONVENTIONS.md`; initialize
`.claude/pipeline/<slug>/`.

## Stage 1.5 — Sanity check

Run `/sdlc` Stage 1.5 inline (sequential pre-flight). Not gated, not optional.
For a range, run once over the combined set. Stop and report on a real blocker.

## Stage 2 — Implement

Run `/sdlc` Stage 2 inline, including its **auto-gate** (see
`.agents/skills/sdlc/SKILL.md`). Compute `surfaces_touched` (planned files vs.
the surface globs) and `task_count` (step count). **Decompose iff**
`surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` (default `6`,
override via `pipeline.decompose_min_tasks`) AND the per-surface file sets are
disjoint.

- **Single-pass (default):** execute the plan/task steps inline, in order. No
  worker handoff. Follow the `Files` section (fill it in as you go).
- **Decompose (large multi-surface plan):** split the files into disjoint lanes
  (data / backend / frontend / docs) with a per-lane interface contract,
  implement each lane in dependency order (one fully before the next, editing
  only that lane's files and coding against the contract), then converge —
  reconcile imports / call sites / shared types and sweep for unresolved imports
  or symbol collisions. Record `stage2_decomposed` + `lanes` and write
  `decompose.json` / `implement-<lane>.json` / `converge.json`.

For a task range the gate sees the combined file/step set. After implementing,
run `git diff --stat` and confirm expected files were touched. Stop on any
blocker.

## Stage 3 — Generate evals

Same procedure as `/sdlc` Stage 3 (see `.agents/skills/sdlc/SKILL.md`):
- new Python pure functions → `tests/eval/test_{slug}_eval.py`,
- scripts with `--input` fixtures → `<eval.features_dir>/{slug}/`,
- no testable surface → note and proceed.

**Skip silently if no `eval.runner` is configured.**

## Stage 4 — Eval + sequential fix loop

Run `<eval.runner> --feature {slug} --output json`. Fix failures inline.
3-iteration budget. On persistent failure: pause, ask the user to fix manually
then re-run. Skip when Stage 3 was skipped.

## Stage 5 — Validate

Invoke `/test-check`. Route new failures through the Stage 4 fix loop (same
3-iteration budget). Pre-existing failures: note and skip.

## Stage 5.5 — Plan requirements validation

Run when a **plan target** exists (plan-file input, or task with `parent_plan`):
re-read the plan, verify each requirement is fulfilled, flag failures, route
findings through the Stage 4 fix loop. **Skip with a note when there is no plan
target** — nothing to validate against, not an arbitrary gate.

## Stage 5.6 — Flowsim

Same condition as 5.5: when a plan target exists, invoke `/flowsim <plan-target>`
and process results per `/sdlc` Stage 5.6; mismatches feed the Stage 4 fix loop.
Skip with a note when none exists.

## Stage 6 — Hand off (no commit, no git writes)

Run the full pipeline, then **stop at the edge of git**. No commit, branch,
push, PR, or `/review`. You review and commit.

1. Secret scan the changed files (gitleaks if available, regex-fallback
   otherwise). **Warn-only** — surface findings (file:line) but never block.
   HIGH findings get a `⚠ HIGH:` prefix; worth scrubbing before you commit.
2. **Report, don't commit.** Show `git diff --stat`, the files changed, and a
   suggested commit message. Do NOT run `git add`, `git commit`,
   `git checkout -b`, `git push`, `gh pr create`, or `/review`. Leave the tree
   as the pipeline produced it.
   ```
   Suggested (run yourself):
     git add <files>
     git commit -m "feat: <title>"
   ```
   **Range**: changes from all tasks accumulate in the tree; you slice the
   commits when you review.
3. Mark each resolved `TASKS.md` row `[x]`, move to `Done`, set
   `status: completed` in the task file(s) — work is done and validated; only
   the commit is left to you.

Write `stage-outputs/handoff.json` =
`{branch, files_changed[], committed: false, suggested_commit_msg}`.
Set `run.json.status = "complete"`.

## Stage 7 — Report

Summarize: branch the changes sit on (uncommitted), files changed, suggested
commit message, eval pass/fail, test-check summary, flowsim status (or
"skipped — no plan target"), anything left open. Make clear **nothing was
committed** — the next move is yours.

## Gotchas

- **Does no git writes.** No commit, branch, push, PR, or `/review`. Hands you
  a validated tree; you commit. Only `/sdlc` touches git history.
- **flowsim/plan-validate run whenever there's a plan to check.** They skip only
  when there is no plan target — not behind a frontmatter knob.
- **Don't fork `/sdlc`'s templates.** If a stage needs different copy, it's a
  `/sdlc` job — re-invoke as `/sdlc`.
- **Range accumulates in the tree** — all tasks' changes land uncommitted
  together; you slice the commits.
