---
name: test-check
description: >
  Run all relevant tests and log audits after code changes. Reads `.claude/project.json`
  for project-specific commands. Gracefully skips any steps whose commands are not
  configured. Use after implementing features, fixing bugs, or before marking work done.
applies-to: [claude, copilot]
---

# Post-Change Validation

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

### 5. Post-test log re-check (if `logs.command` defined)

Re-run the log audit to catch issues triggered by the tests themselves. Compare with
Step 1 findings. Any NEW issues are likely caused by the test run and should be
investigated.

## Rules

- Always run Step 1 if `logs.command` is defined.
- Run Steps 2-4 only if the corresponding key is defined AND files in the corresponding
  area changed.
- Always run Step 5 after tests complete, if Step 1 ran.
- If ANY check fails, report the failure clearly and do NOT mark work as complete.
- Summarize results at the end: which checks passed, which failed, what needs fixing.
- If `.claude/project.json` does not exist, report: "No project.json — no checks to run"
  and suggest the user create one.
- If a non-obvious pitfall is discovered, add a gotcha via `/gotcha [Category] description`.
