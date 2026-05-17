---
name: tasker
description: >
  Sequential task-row pipeline for Copilot. Resolves or creates a TASKS.md
  row, implements, generates and runs evals, validates with /test-check,
  runs flowsim when a parent plan is set, and commits on the current branch.
  No branch creation, no push, no PR. Copilot-optimized overlay of the
  canonical /tasker — every stage runs inline (no parallel sub-agents,
  no Plan mode). Use when a task is too big for /task's TDD inner loop but
  too small to justify the full /sdlc plan-to-PR pipeline.
argument-hint: "<description-or-task-id>"
metadata:
  brainstorm-toolkit-applies-to: copilot
disable-model-invocation: true
---

# Tasker (Copilot Edition — Sequential)

Sequential version of the `/tasker` pipeline. Canonical `/tasker` uses parallel agent dispatch for Stage 5.5 validators on Claude; this overlay executes every stage inline, one at a time.

When Copilot's VS Code agent mode gains parallel sub-agent support, this overlay can be upgraded.

## When to use

| Skill | Input | Terminal action |
|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red-green → green commit on current branch |
| `/tasker <description-or-task-id>` | task-row work | implement → evals → validate → flowsim → commit on current branch |
| `/sdlc <plan-file>` | plan file | full pipeline → PR |

`/tasker` reuses `/sdlc`'s stage templates and state envelope verbatim — no new templates, no new state schema beyond `run.json.pipeline = "tasker"` and a `commit.json` sidecar at Stage 6.

## Prerequisites

- Git working tree clean enough that this run's commit can be cleanly staged.
- `.claude/project.json` may exist; every key is optional. Eval and flowsim stages skip silently when their config is absent.

## Stage 1 — Resolve task

If the argument matches `task-NNN` or a TASKS.md row number, read the existing row and the linked `plans/tasks/task-N-<slug>.md`. Mark the row `[~]`.

Otherwise, create a new row using the same procedure `/task` uses: determine the next task number, slugify, append to `Active / Pending`, and write `plans/tasks/task-<N>-<slug>.md` with the standard frontmatter. Mark `[~]`.

Derive `task_slug` from the task filename per `docs/CONVENTIONS.md`. Initialize `.claude/pipeline/<task_slug>/`.

## Stage 2 — Implement

Execute the task file's steps inline, in order. No worker handoff. Follow the file paths in the task file's `Files` section (or fill that section in as you go). Stop and report on any blocker.

After implementation, run `git diff --stat` and confirm expected files were touched.

## Stage 3 — Generate evals

Same procedure as `/sdlc` Stage 3 (see `.github/skills/sdlc/SKILL.md`):
- New Python pure functions → `tests/eval/test_{slug}_eval.py`.
- Scripts with `--input` fixtures → `<eval.features_dir>/{slug}/fixtures` + `expected`.
- No testable surface → note and proceed.

**Skip silently if no `eval.runner` is configured.** Pure-docs tasks degenerate cleanly into docs-edit + commit.

## Stage 4 — Eval + sequential fix loop

Run `<eval.runner> --feature {task_slug} --output json`. Fix failures inline. 3-iteration budget. On persistent failure: pause, ask the user to fix manually then re-run.

Skip when Stage 3 was skipped.

## Stage 5 — Validate

Invoke `/test-check`. Route new failures through the Stage 4 fix loop (counts toward the same 3-iteration budget). Pre-existing failures: note and skip.

## Stage 5.5 — Plan validators (conditional)

**Only run if the task file's frontmatter declares `parent_plan: <path>`.** Otherwise skip silently.

When set, walk the same checklist `/sdlc` Stage 5.5 uses, inline: re-read the parent plan, verify each requirement is fulfilled by the implementation, flag failures. Route findings through the Stage 4 fix loop.

## Stage 5.6 — Flowsim (conditional)

**Only run if `parent_plan` is set.** Otherwise skip silently.

When set, invoke `/flowsim <parent_plan>` and process results per `/sdlc` Stage 5.6. Mismatches feed back through the Stage 4 fix loop.

## Stage 6 — Commit

1. Secret scan the files about to be staged (gitleaks if available, regex-fallback otherwise). **Warn-only** — surface findings (file:line) in the commit notes but never block the commit. HIGH findings get a `⚠ HIGH:` prefix; GitHub Push Protection may still reject the push on public remotes.
2. Stage and commit on the **current branch** (no branch creation):
   ```
   git add <specific files>
   git commit -m "feat: <task title>

   Implemented via /tasker from <task-file>."
   ```
3. **Do NOT** push, create a PR, or invoke `/review`. Stay on the current branch.
4. Mark the TASKS.md row `[x]`, move to `Done`, set `status: completed` in the task file.

Write `stage-outputs/commit.json` with `{branch, commit_sha, files_committed[]}`. Set `run.json.status = "complete"`.

## Stage 7 — Report

Summarize: task row closed, commit SHA, eval pass/fail, test-check summary, flowsim status (when run), anything left open.

## Gotchas

- **Don't fork templates.** If a stage genuinely needs different prompt copy than `/sdlc`, the task is probably big enough for `/sdlc` — re-invoke as `/sdlc`.
- **No PR.** `/tasker` never branches, pushes, or opens a PR. Use `/sdlc` for that.
- **`parent_plan` is the only conditional knob.** Don't add others.
