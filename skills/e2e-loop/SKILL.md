---
name: e2e-loop
description: >
  Run end-to-end tests in a fix loop — the browser/UI counterpart to /eval-harness.
  Runs the configured test.e2e command, detects flaky tests, dispatches a fix agent
  for real failures, and re-runs until green or max_fix_loops is hit. Reads
  .claude/project.json for commands and optional patterns file. Use after changes
  that touch UI flows or on-demand for flaky-test triage. For one-shot e2e without
  the loop, use /test-check instead.
argument-hint: "[focus] — optional: test file, directory, or grep pattern to narrow the run"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# E2E Loop

User-invocable wrapper around the `e2e-test-runner` agent. Runs e2e tests with a
fix loop for real failures and a flaky-test guard.

## When to use

- After modifying UI flows, frontend components, or anything that touches an e2e-tested path
- When the same e2e test has failed multiple times and you want automated triage
- As a standalone alternative to `/test-check` when you want fix-on-failure behavior
- `/sdlc` Stage 5 dispatches the underlying agent automatically — this skill is the standalone entry point

Not for:
- One-shot validation (use `/test-check`)
- Unit/pytest fix loops (use `/eval-harness --fix-loop`)

## Config

Reads `.claude/project.json`. Only `test.e2e` is required:

```json
{
  "test": {
    "e2e": "npx playwright test --reporter=json",
    "e2e_max_fix_loops": 3,
    "e2e_patterns_file": ".claude/e2e-patterns.md",
    "e2e_rerun_failed_only": true
  }
}
```

If `test.e2e` is missing: report and exit. Do not guess a command.

## Procedure

### Step 1 — Dispatch the e2e-test-runner agent

```
Agent(
  subagent_type: "general-purpose",
  description: "Run e2e loop for {focus or 'full suite'}",
  prompt: """
    Execute the e2e-test-runner agent defined at .claude/agents/e2e-test-runner.md.

    Inputs:
      feature_slug: {derived from focus, or 'adhoc'}
      focus: {user-provided focus, or omitted for full suite}
      max_fix_loops: {from args, or default 3}

    Follow the agent's Loop section (Steps 1-9) exactly. Return its final
    structured report verbatim.
  """
)
```

### Step 2 — Present the agent's report

Relay the agent's structured markdown report to the user. Do not summarize away the
Flaky tests section — flakes are signal, not noise.

### Step 3 — Suggested next actions (based on exit status)

- `success`: note any flaky tests for future investigation; no further action.
- `failed_after_max_iterations`: list the persistent failures, suggest running again with a larger `--max-fix-loops`, checking the patterns file, or reviewing the specific tests manually.
- `blocked`: surface the reason (unparseable output, missing command, config gap) — do not retry without a fix.

## Availability By Tool

| Capability | Claude Code | GitHub Copilot |
|---|---|---|
| Loop orchestration | Yes (dispatches agent) | Yes (inline sequential) |
| Flaky-test guard | Yes | Yes |
| Structured report | Yes | Yes |
| Fix-agent dispatch | Yes (subagent) | Runs fixes in the main context |

The Claude version dispatches `agents/e2e-test-runner.md` as a subagent. The Copilot
override runs the same loop inline in the main context — same behavior, no agent.
