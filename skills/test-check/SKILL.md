---
name: test-check
description: >
  Run all relevant tests, feature evals and log audits after code changes. Reads `.claude/project.json`
  for project-specific commands. Gracefully skips any steps whose commands are not
  configured. Use after implementing features, fixing bugs, or before marking work done.
argument-hint: "[--loop]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Post-Change Validation

## Run the suites in a sub-agent (default)

**Dispatch the `test-runner` agent** — by type `brainstorm-toolkit:test-runner`, or bare
`test-runner` when vendored — rather than running the commands in your own context. It is
pinned to **Haiku** (running a command and classifying its exit status is mechanical) and
returns `{layers, failures[], preexisting[], green, totals}` and nothing else.

**Why this is the default, not an option.** Test output is the largest single source of shell
traffic, and shell traffic was ~53% of main-thread tokens on an audited run. Raw runner output
taken into the orchestrator's context stays there for the rest of the session and is re-read on
every subsequent turn; taken by a sub-agent, it is discarded when the agent returns. You need
`{name, file, expected, actual}` to write a fix — not 400 lines of pytest.

Run a command inline only when you are **debugging the runner itself** (it won't start, the
config is wrong) and need to see raw output. Say so when you do.

On a runtime with no sub-agent seam (Copilot / Codex), you are the runner: run the commands
yourself, but report the structure above and do not paste the raw output back into your own
narration.



Runs a deep post-change check. Reads commands from `.claude/project.json`. Any key that
is missing causes the corresponding step to be skipped — that's intentional, it lets
projects opt in to whichever layers apply.

## Config keys read

```json
{
  "test": {
    "unit": "...",        // backend/unit test command
    "frontend": "...",    // frontend test command
    "e2e": "..."          // end-to-end test command
  },
  "logs": {
    "command": "...",     // e.g. "docker compose logs --tail 200"
    "services": [...]     // optional list of service names
  },
  "eval": {
    "runner": "...",      // e.g. "python3 scripts/eval-runner.py"
    "features_dir": "..." // where per-feature fixtures/expected live
  }
}
```

## Steps

### 1. Log audit (if `logs.command` defined)

Run the log-audit script, which parses logs via the configured command:

```bash
python3 scripts/check_docker_logs.py --output json \
  --log-command "<logs.command>" \
  --services <logs.services>
```

Parse the JSON output:
- If any CRITICAL findings: stop and fix before running other tests.
- If HIGH findings: note them, continue, report at end.
- MEDIUM/LOW: proceed normally.

If `logs.command` is not defined in config, skip this step silently.

### 2. Frontend unit tests (if `test.frontend` defined and frontend files were changed)

```bash
<test.frontend>
```

Skip if the key is missing.

### 3. Backend unit tests (if `test.unit` defined and backend files were changed)

```bash
<test.unit>
```

Skip if the key is missing.

### 4. E2E tests (if `test.e2e` defined and UI flow was changed)

```bash
<test.e2e>
```

Skip if the key is missing.

**`--loop` — fix e2e failures instead of only reporting them** (absorbed from the former
`/test-check --loop`). With `--loop`, dispatch the `e2e-test-runner` agent (by type:
`brainstorm-toolkit:e2e-test-runner`, or bare `e2e-test-runner` when vendored) rather than
running the command inline — Sonnet by default, per `skills/sdlc/templates/models.md`; pass
`model` explicitly, since the agent pins no tier and an omitted `model` inherits the session
model. It separates flaky failures from real ones, re-runs each failure
once before believing it, dispatches fixes, and re-runs until green or `test.e2e_max_fix_loops`
(default 3) is hit. It also reads `test.e2e_patterns_file` and `test.e2e_rerun_failed_only`
when set. Without `--loop`, this step stays one-shot: run, report, don't fix.

The agent was always the thing doing the work — `/e2e-loop` was a second entry point to it,
and `/sdlc` Stage 5 a third. One skill, one flag.

### 5. Post-test log re-check (if `logs.command` defined)

Re-run the log audit to catch issues triggered by the tests themselves. Compare with
Step 1 findings. Any NEW issues are likely caused by the test run and should be
investigated.

### 6. Feature evals (if `eval.runner` defined)

Run the configured runner and read its structured result, never its raw output:

```bash
<eval.runner> --output json            # whole suite
<eval.runner> --feature <slug> --output json   # one feature
```

The runner auto-discovers features from `<eval.features_dir>/*/`, so a new feature needs no
registration. Report pass/fail per feature plus `min_pass_rate` if `eval.thresholds` is set;
route failures through the same fix loop as the other suites. Authoring new evals is not this
skill's job — that is the pipeline's Stage 3
(`skills/sdlc/templates/stage-3-evals.md`).

## Rules

- Always run Step 1 if `logs.command` is defined.
- Run Steps 2-4 and 6 only if the corresponding key is defined AND files in the
  corresponding area changed.
- Always run Step 5 after tests complete, if Step 1 ran.
- If ANY check fails, report the failure clearly and do NOT mark work as complete.
- Summarize results at the end: which checks passed, which failed, what needs fixing.
- If `.claude/project.json` does not exist, report: "No project.json — no checks to run"
  and suggest the user create one.
- If a non-obvious pitfall is discovered, add a gotcha via `/gotcha [Category] description`.
