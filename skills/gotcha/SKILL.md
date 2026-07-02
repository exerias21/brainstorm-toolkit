---
name: gotcha
description: >
  Maintains a running log of project-specific "gotchas" — non-obvious pitfalls, traps, and hard-won
  lessons that have caused bugs or wasted time in this codebase. Use this skill proactively whenever
  writing or modifying code in any area where a prior gotcha has been recorded. Also use when the
  user invokes /gotcha to add a new entry or review existing ones. Consult the project's GOTCHAS.md
  before writing code in any area where a known pitfall exists.
argument-hint: "[category] description of the gotcha"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Gotcha Log

This skill manages a living document of project-specific pitfalls.

## Config

Reads `gotchas_file` from `.claude/project.json` (default: `GOTCHAS.md` at the repo root).

## When invoked with `/gotcha` (no arguments)

Read and display the current gotcha list from the configured file, organized by category.
Summarize the count per category and highlight any gotchas relevant to recent conversation
context.

## When invoked with `/gotcha <text>`

Add a new entry to the gotchas file. Parse the argument to extract:
- **Category**: Match against existing categories, or infer from context. If the text starts
  with a category tag in brackets like `[Database]` or `[Testing]`, use that. Otherwise,
  infer from keywords.
- **Title**: A short, scannable name for the gotcha.
- **Description**: What goes wrong — the surprising or non-obvious behavior.
- **Why**: Why this happens (root cause).
- **Fix**: The correct approach or workaround.

Use this format when appending:

```markdown
### Title Goes Here
**Added**: YYYY-MM-DD
**Why**: Root cause explanation.
**Fix**: The correct approach.

Description of the gotcha — what goes wrong and how you'd encounter it.
```

Place the entry under the correct category heading. If the gotchas file doesn't exist,
create it with a default category structure (see below). If a similar gotcha already
exists, update it rather than creating a duplicate.

## When writing code (automatic / model-invoked)

Before writing or modifying code, read the configured gotchas file and check whether any
listed gotchas apply to the code you're about to write. If a gotcha applies, follow its
prescribed fix. You don't need to mention the gotcha to the user unless it materially
changes your approach from what they might expect.

## Capture at loop-exit (model-invoked) — the shared protocol

The delivery skills (`/task`, `/sdlc-lite`, `/sdlc`) run this at the end of a
run. Goal: turn a hard-won trap into a durable entry **without capture fatigue**.

**Objective trigger — auto-draft ONLY on hard evidence of a trap:**
- a test / eval / flowsim fix-loop actually ran and **failed-then-recovered**, or
- the user explicitly voiced surprise ("huh", "that's a gotcha", "didn't expect").

A clean run (no fix-loop, no surprise) produces **no prompt** — skip silently.
Do not gate on a vibe like "was anything non-obvious?"; that fires every run.

**When triggered:** auto-draft the entry yourself in the format above (don't make
the user compose it), route it through the **dedup check** (update a similar
existing entry, never duplicate), and ask a **single** confirm before writing.
Create `gotchas_file` only on confirm. Emit `/gotcha <drafted text>` — never a
bare `/gotcha` (that's review mode). If the user declines, the caller may drop a
`.next-action` sentinel instead (see each delivery skill's seam step).

## Default Categories

When creating a new gotchas file, start with these category headings (omit any that
don't apply to the project):

- Database/SQL
- Auth/Session
- API/Routing
- Frontend
- Testing
- Integrations (LLM, third-party APIs, webhooks)
- Infra (Docker, deployment, environment)
- Logging/Observability
- Code Hygiene

Projects should add, remove, or rename categories to fit their domain.
