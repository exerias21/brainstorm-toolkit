---
name: task
description: >
  Create a bounded, single-purpose task and execute it with TDD. Appends a row to
  TASKS.md, writes a task file at plans/tasks/task-N-<slug>.md, and runs a write-test
  → implement → verify loop. Use for small to medium items that are too concrete for
  /brainstorm and too small to justify the full /sdlc pipeline. Invoke via /task or
  when the user asks to "just do X" with a clear, bounded ask.
argument-hint: "<description> [--defer] [--no-test]"
applies-to: [claude, copilot]
---

# Task — single-task TDD execution

## When to use

- User has a clear, bounded ask: "add a `formatPhone` util", "fix the bug where X", "rename Y to Z across the codebase".
- Too small for `/sdlc`, too concrete for `/brainstorm`.
- Use `--defer` to only create the files without executing; use `--no-test` to skip the failing-test-first step (rare — e.g., pure docs).

## Flow

### 1. Prepare the task record

1. **TASKS.md**: if missing, create it from `templates/TASKS.md.template` (or from scratch with sections `Active / Pending`, `Blocked`, `Done`).
2. **Determine the next task number** by reading existing rows (`(P?) <title> — plans/tasks/task-<N>-...`) and taking `max(N) + 1`. Start at 1 if empty.
3. **Slugify the description** (lowercase, hyphen-separated, ≤40 chars).
4. **Append a row** to the `Active / Pending` section: `- [ ] (P2) <one-line title> — plans/tasks/task-<N>-<slug>.md`.

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

### 4. Stop here if `--defer`

Report the files written and the next command to run manually. Do not proceed to execution.

### 5. Execute with TDD

Unless `--no-test` is passed:

1. **Write a failing test** that encodes the acceptance criterion. Use the project's configured test runner (`.claude/project.json` → `test.unit` or `test.frontend`). If the project has no tests, write one in the conventional location (`tests/`, `__tests__/`, etc.).
2. **Run the test** and confirm it fails for the expected reason. If it passes, the test is wrong — fix it before continuing.
3. **Mark the TASKS.md row as in-progress** (`[ ]` → `[~]`) and, on Claude, `TaskUpdate status: in_progress`.
4. **Implement the change**, following existing patterns. Keep the diff minimal.
5. **Re-run the test** until it passes. Do not weaken the test to make it pass.
6. **Run the wider test suite** if one is configured (`/test-check` or the project's root test command).

### 6. Close out

1. **Update the task file**: set `status: completed`, mark all step checkboxes `[x]`, fill in `Files` with the actual paths touched.
2. **Mark the TASKS.md row done** (`[~]` → `[x]`) and move it to the `Done` section.
3. On Claude: `TaskUpdate status: completed`.
4. Report a concise summary: files touched, tests that now pass, anything left open.

Commit only if the user asked for it, or if they have a durable "always commit finished tasks" instruction.

## Gotchas

- **Don't inflate small tasks.** If the ask is one line of code, the task file can be terse. Don't pad acceptance criteria to look thorough.
- **Respect `GOTCHAS.md`.** Before writing code, check for entries that apply to the area you're touching.
- **Don't skip the failing-test step** without `--no-test`. A passing test that was never red verifies nothing.
- **One task at a time.** If the ask implies multiple tasks, invoke `/task` once per item or suggest `/brainstorm` or `/sdlc` instead.
