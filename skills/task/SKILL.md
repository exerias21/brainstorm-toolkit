---
name: task
description: >
  Create a bounded, single-purpose task and execute it with TDD. Appends a row to
  TASKS.md, writes a task file at plans/tasks/task-N-<slug>.md, and runs a write-test
  → implement → verify loop. Use for small to medium items that are too concrete for
  /brainstorm and too small to justify the full /sdlc pipeline. Invoke via /task or
  when the user asks to "just do X" with a clear, bounded ask.
argument-hint: "<description>"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Task — single-task TDD execution

## When to use

- User has a clear, bounded ask: "add a `formatPhone` util", "fix the bug where X", "rename Y to Z across the codebase".
- Too small for `/sdlc`, too concrete for `/brainstorm`.
- `/task` always executes TDD on the current branch. If you want the full pipeline (evals + validate + flowsim + commit, but no PR), use `/sdlc-lite`. If you want just the row written and nothing run, edit `TASKS.md` directly.

## Flow

### 1. Prepare the task record

1. **TASKS.md**: if missing, create it from `templates/TASKS.md.template` (or from scratch with sections `Active / Pending`, `Blocked`, `Done`).
2. **Determine the next task number** by reading existing rows (`(P?) <title> — plans/tasks/task-<N>-...`) and taking `max(N) + 1`. Start at 1 if empty.
3. **Slugify the description** (lowercase, hyphen-separated, ≤40 chars).
4. **Append a row** to the `Active / Pending` section: `- [ ] (P2) <one-line title> — plans/tasks/task-<N>-<slug>.md`.
5. **Initialize a minimal state record** (best-effort): write
   `.claude/pipeline/task-<N>-<slug>/run.json` with `{schema_version: 1,
   feature_slug: "task-<N>-<slug>", pipeline: "task", stage: "implement",
   status: "in_progress", started_at}` (shape per
   `skills/sdlc/templates/state-schema.md`). This puts `/task` runs in the
   same state journal as `/sdlc` and `/sdlc-lite`. If the write fails
   (permissions, read-only volume), log a one-line stderr warning and
   continue — **state writes never fail a task.**

### 2. Write the task file

Create `plans/tasks/task-<N>-<slug>.md`:

```markdown
---
id: task-<N>
status: pending
priority: P2
files: []
---

# <Title>

## Description
<1–3 sentences restating the ask.>

## Steps
- [ ] <first concrete step>
- [ ] <next step>

## Acceptance criteria
- <observable condition for done>

## Files
<expected paths to create/modify; fill in as you go>

## Notes
<open questions, links, context>
```

### 3. (Claude only; optional) Mirror to native Tasks

If running under Claude Code, call `TaskCreate` with the same title. This gives the user a live progress indicator in the UI. Skip silently on other agents.

### 4. Execute with TDD

**Pure-docs / no-testable-surface asks**: if the change has nothing to assert
against (docs, comments, config, copy edits), skip steps 1, 2, and 5 — make
the edit directly at step 4 and note "no testable surface" in the report.
Don't manufacture a hollow test, and don't punt the task to another skill.

1. **Write a failing test** that encodes the acceptance criterion. Use the project's configured test runner (`.claude/project.json` → `test.unit` or `test.frontend`). If the project has no tests, write one in the conventional location (`tests/`, `__tests__/`, etc.).
2. **Run the test** and confirm it fails for the expected reason. If it passes, the test is wrong — fix it before continuing.
3. **Mark the TASKS.md row as in-progress** (`[ ]` → `[~]`) and, on Claude, `TaskUpdate status: in_progress`.
4. **Implement the change**, following existing patterns. Keep the diff minimal.
5. **Re-run the test** until it passes. Do not weaken the test to make it pass.
6. **Run the wider test suite** if one is configured (`/test-check` or the project's root test command).

### 5. Close out

1. **Update the task file**: set `status: completed`, mark all step checkboxes `[x]`, fill in `Files` with the actual paths touched.
2. **Mark the TASKS.md row done** (`[~]` → `[x]`) and move it to the `Done` section.
3. On Claude: `TaskUpdate status: completed`.
4. **Update the state record** (best-effort): set `run.json.status = "complete"`,
   `stage = "done"`, and record the `files` touched (and `commit_sha` if you
   committed). Same never-fail rule as Section 1.
5. Report a concise summary: files touched, tests that now pass (or "no testable surface"), anything left open.

Commit only if the user asked for it, or if they have a durable "always commit finished tasks" instruction.

## Gotchas

- **Don't inflate small tasks.** If the ask is one line of code, the task file can be terse. Don't pad acceptance criteria to look thorough.
- **Respect `GOTCHAS.md`.** Before writing code, check the configured `gotchas_file` (if it exists) for entries that apply to the area you're touching — scoped to the touched area, not the whole file.
- **Capture at exit (flywheel).** If the run hit a real trap (a test flipped red→green, or something surprised you), run the loop-exit capture protocol in `skills/gotcha/SKILL.md` — auto-draft + one-tap confirm; clean runs stay silent. If capture is declined/deferred, drop a `/gotcha <drafted text>` `.next-action` sentinel (no-op if one already exists; never a bare `/gotcha`).
- **Don't skip the failing-test step when there IS a testable surface.** A passing test that was never red verifies nothing. Only skip the red-test cycle for genuinely untestable asks (pure docs/config/copy) — handle those directly here per the note in Section 4; don't punt them to another skill.
- **One task at a time.** `/task` handles a single bounded item. If the ask implies a *batch* of tasks, don't fire `/task` repeatedly — run them through `/sdlc-lite <range>` (e.g. `/sdlc-lite 1-5`), which keeps full-pipeline discipline across the set and commits nothing until you review. For an open-ended feature, start with `/brainstorm`.
