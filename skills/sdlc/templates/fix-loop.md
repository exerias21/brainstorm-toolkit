# Shared fix loop + pause shape

Canonical for every gate that fixes and retries — `/sdlc`
Stage 5, and Stage 5.7/5.8.

Stage 5 and Stage 5.7/5.8 fix the same way, so the loop and its pause are specified once, here.
**The loop.** On a gate failure: parse the structured results; for each failure extract test
name, expected-vs-actual, file path, function; dispatch **one fix agent** — **Sonnet by default**
(Opus only on `--model opus`), per `skills/sdlc/templates/models.md` — told to fix *only* those failures
with no refactor; re-run the gate. Repeat to a maximum of **3 iterations, shared across Stage
5's gates** (Stage 5.7/5.8 has its own separate budget).

**The pause.** On budget exhaustion, emit this block, inferring the class from *the failing
stage's own* sidecar (`validate.json`, `review.json`):

```markdown
## SDLC Pipeline — PAUSED

{stage} failures persist after {N} fix attempts.
Remaining failures:
{failures_summary}

### Diagnosis

**Fastest path: run `/sdlc-status`** — it reads this sidecar, classifies the failure,
drafts the fix for a code defect, and hands back the `--resume` re-entry. Or triage inline:
- **Class** (inferred from the failing stage's sidecar `data.remaining_failures[]`): one of
  **flaky** (a test flips pass/fail across loops) · **code-defect** (a consistent assertion
  failure) · **plan-wrong** (the failure contradicts a plan step) · **config-missing** (a
  command/env/dep the runner needs).
- **Recommended next command** (matches the class — `--resume` reuses the green stages, so
  prefer it over a fresh re-run):
  - flaky → re-run just the gate to confirm: `/test-check`; if green, `/sdlc {plan_file} --resume`.
  - code-defect → `/task fix: {one-line failure}` (bounded TDD), then `/sdlc {plan_file} --resume` (code changed, plan didn't).
  - plan-wrong → `/brainstorm` the failing step to revise `{plan_file}`, then re-run `/sdlc {plan_file}` **fresh** (NOT `--resume` — editing the plan changes its hash, which resume rejects by design).
  - config-missing → set the missing command/env in `.claude/project.json`, then `/sdlc {plan_file} --resume`.

Fix manually (per the diagnosis above), then `/sdlc {plan_file} --resume` (or a
fresh `/sdlc {plan_file}` if you edited the plan) — resume reuses the green stages.
```

Set `run.json.status = "paused"` alongside the failing stage's sidecar `status: "paused"`.

