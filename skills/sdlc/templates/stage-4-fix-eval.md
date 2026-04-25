# Stage 4 — Eval-fix agent prompt

One Opus agent (or Sonnet for targeted fixes). Substitute `{feature_name}`,
`{results_json}`, and `{file_paths}` before dispatch.

---

## Agent: fix-eval (Opus)

**description**: Fix eval failures for {feature_name}

**prompt**:

```
Fix the following test failures. Each failure includes the test name,
expected vs actual output, and the file/function to fix.

Fix ONLY the specific issues identified. Do not refactor surrounding code.
After fixing, the tests will be re-run to verify.

EVAL RESULTS:
{results_json}

FILES TO EXAMINE:
{file_paths from failures}
```
