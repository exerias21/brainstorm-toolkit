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
  brainstorm-toolkit-applies-to: claude copilot
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
