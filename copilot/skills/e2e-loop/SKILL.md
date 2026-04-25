---
name: e2e-loop
description: >
  Run end-to-end tests in a fix loop — the browser/UI counterpart to /eval-harness.
  Runs the configured test.e2e command, detects flaky tests, applies targeted fixes
  for real failures, and re-runs until green or max_fix_loops is hit. Reads
  .claude/project.json for commands and optional patterns file. Copilot sequential
  edition — the canonical dispatches a subagent; this version runs the loop inline.
argument-hint: "[focus] — optional: test file, directory, or grep pattern"
metadata:
  brainstorm-toolkit-applies-to: copilot
disable-model-invocation: true
---

# E2E Loop (Copilot Edition — Inline)

The Claude canonical dispatches `agents/e2e-test-runner.md` as a subagent. This Copilot
version runs the same loop inline in the main context. Same behavior, no agent tool.

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

If `test.e2e` is missing: report `"No test.e2e configured — cannot run."` and exit.

## Project context to load first

Read, skipping any that don't exist:
- `README.md`, `CLAUDE.md` / `AGENTS.md`
- `test.e2e_patterns_file` — repo-specific auth setup, navigation quirks, test user
- `GOTCHAS.md`

Do NOT embed repo-specific patterns in your behavior. Read them from the patterns file.

## Loop

### Step 1 — Pre-test log audit

If `logs.command` is configured, run `scripts/check_docker_logs.py` and record severity counts. Otherwise skip.

### Step 2 — Run e2e

Run `<test.e2e>`, narrowed to `focus` if provided. Capture stdout, stderr, exit code, and any JSON/JUnit artifacts.

### Step 3 — Parse results

Prefer JSON reporter output. Fall back to JUnit XML. Fall back to text regex. If parsing fails entirely, report raw output and exit.

### Step 4 — Flaky-test guard

For each failure, re-run it once in isolation. If it passes on retry → **flaky** (report, don't fix-loop). If it fails again → **real** (include in fix loop). Skip step if no failures.

### Step 5 — Fix real failures

For each real failure, apply a targeted fix:
- Read the failing test file and the suspected source file
- Consult `test.e2e_patterns_file` before editing auth/nav-related tests
- Fix ONLY the specific issue. Don't refactor.
- Don't modify the test itself unless the error clearly indicates a test bug.

### Step 6 — Re-run

- If `test.e2e_rerun_failed_only` is true and this isn't the final iteration: re-run only the previously-failing tests.
- On the final iteration or if the flag is false: re-run the full suite to catch regressions.

### Step 7 — Loop control

- All pass → proceed to Step 8.
- Failures remain and iteration < `max_fix_loops` → increment, return to Step 5.
- Failures remain and iteration == `max_fix_loops` → stop, mark `failed_after_max_iterations`, proceed to Step 8.

### Step 8 — Post-test log audit

Re-run log audit. Diff against Step 1 counts. Attribute new CRITICAL/HIGH issues to the test run.

### Step 9 — Report

Structured markdown:

```markdown
## E2E Test Run: {feature_slug}

### Summary
- Command: `{test.e2e}`
- Focus: {focus or "full suite"}
- Iterations: {N} / {max_fix_loops}
- Final result: PASS / FAIL
- Tests: {X} passed, {Y} failed, {Z} flaky (⚠️), {W} skipped

### Flaky tests (⚠️)
For each flaky test: name, passed-on-retry, file:line.
Recommend investigating separately — flakes compound.

### Failures (if any remain)
For each failure: test name, file:line, assertion error, browser console errors,
screenshot path, what was tried in the fix loop, suggested next step.

### Log audit diff
- Pre-test: {N CRITICAL, M HIGH, ...}
- Post-test: {N' CRITICAL, M' HIGH, ...}
- New issues during test run: {list, or "none"}

### Exit status
- `success` — all green
- `failed_after_max_iterations` — failures persist
- `blocked` — could not parse output, could not run, config gap, etc.
```

Keep the structure stable — `/sdlc` and humans both consume this report.

## Rules

- Read the patterns file before editing tests
- Don't modify application code without justification from failure data
- Preserve flaky-test signal — always include in ⚠️ section even when the run passes
- Never commit, push, or create a PR — that's `/sdlc`'s job
- Never skip tests to make the run green
- Graceful skip when `test.e2e` is missing
