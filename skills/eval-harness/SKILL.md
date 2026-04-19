---
name: eval-harness
description: >
  Run feature evals — pytest function tests + fixture pipeline simulation.
  Validates that scripts and features work correctly against known inputs.
  Outputs structured JSON results. Optionally auto-fixes failures via agent loop.
  Use after implementing or modifying scripts, or as part of /test-check.
argument-hint: "[feature] — name of a feature under evals/, or 'all'"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# Feature Eval Harness

Run structured tests against feature implementations. Two layers:

1. **Layer 1 — pytest**: Function-level tests for pure logic (classification, parsing, categorization). Fast, no browser.
2. **Layer 2 — pipeline simulation**: Run the actual script with `--input` fixture data, compare JSON output against expected results.

## Config

Reads `.claude/project.json` for:

```json
{
  "eval": {
    "runner": "python3 scripts/eval-runner.py",
    "features_dir": "evals/"
  }
}
```

If `eval.runner` is missing, the skill cannot proceed — report:
"No `eval.runner` in `.claude/project.json` — install an eval runner first."

## When to Use

- After implementing or modifying any script that has evals
- After modifying classification logic, parsing rules, or categorization keywords
- As part of `/test-check`
- To validate a feature before creating a PR

## Procedure

### Step 1 — Run the eval runner

```bash
<eval.runner> --feature <feature> --output json
```

Use `--feature all` to run every feature. The runner discovers features by scanning
`<eval.features_dir>/*/`.

### Step 2 — Parse results

The JSON output contains per-layer pass/fail counts and failure details:

```json
{
  "feature": "example-feature",
  "overall": "PASS",
  "total": 46,
  "passed": 46,
  "failed": 0,
  "layers": [
    {"name": "classification-logic", "type": "pytest", "total": 44, "passed": 44, "failed": 0},
    {"name": "pipeline-simulation", "type": "subprocess", "total": 2, "passed": 2, "failed": 0}
  ]
}
```

### Step 3 — Report findings

Present results in a table. If all green, report success. If failures:
- Show each failure with test name, expected vs actual, and file location
- For pipeline failures, show the specific diff between expected and actual output

### Step 4 — Fix loop (optional)

If invoked with `--fix-loop N` or if the user requests auto-fix:

1. Parse the failures from the JSON output
2. Spawn a fix agent with the structured failure data
3. The fix agent reads: test name, expected value, actual value, file path, function name
4. Agent fixes ONLY the specific issues identified
5. Re-run the eval
6. Repeat up to N times or until all green

**Fix agent prompt template:**
```
Fix the following test failures. Each failure includes the test name,
expected vs actual output, and the file/function to fix.

Fix ONLY the specific issues. Do not refactor surrounding code.

Failures:
{failures_json}

Files to examine:
{file_paths}
```

## Adding Evals for a New Feature

1. Create `tests/eval/test_{feature}_eval.py` with parameterized test cases
2. Create `<eval.features_dir>/{feature}/fixtures/*.json` with input data
3. Create `<eval.features_dir>/{feature}/expected/*.json` with expected output
4. The runner auto-discovers the feature on next invocation — no registration needed.
