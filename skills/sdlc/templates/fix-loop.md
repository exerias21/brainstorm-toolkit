# Shared fix loop + pause shape

Canonical for every gate that fixes and retries — `/sdlc`
Stage 5, and Stage 5.7/5.8.

Stage 5 and Stage 5.7/5.8 fix the same way, so the loop and its pause are specified once, here.
**The loop.** On a gate failure: parse the structured results; for each failure extract test
name, expected-vs-actual, file path, function; dispatch **one fix agent** — tier `models.fix`
(Sonnet default, capped), per `skills/sdlc/templates/models.md` — told to fix *only* those failures
with no refactor, and given these four blocks verbatim in its prompt:

> GIT: never run a git command that writes — no stash, commit, checkout, switch, reset, restore, rebase, merge, clean, or branch creation. The working tree holds the user's uncommitted work; git that only reads (status, diff, log, show) is fine. If you need a clean baseline, report it as a blocker instead.

> never write plan or task references (plans/ paths, task IDs, brainstorm names) into code — this covers comments, docstrings, string literals and data (e.g. `TASKS.md:N`, `task-N`, `plans/<file>.md`, phase/step numbers, a plan slug). Write the reason itself: the plan is deleted once delivered and TASKS.md rows move, so the reference rots.

> MUST FOLLOW:
> - Start a long test run once in the background and wait for its completion notice; never poll with sleep/until loops. Iterate on changed test files only; run the full suite once at the end.
> - Format with the repo's own formatter, on files you changed only; never reformat whole files or untouched files.
> {must_follow_extra}
> - Never edit TASKS.md; report any row to add or close in the hand-back.

> Hand-back: write full detail to `.claude/pipeline/{slug}/agent-reports/{gate}-fix-{iteration}.md`, reply with at most 40 lines plus that path, and list every path you edited.

Before each dispatch substitute `{slug}`, `{gate}` (`validate` for Stage 5, `review` for Stage 5.8 —
the two loops count rounds separately, so without it their reports overwrite each other),
`{iteration}` (1-based fix round) and `{must_follow_extra}`
(each `pipeline.implement.must_follow` entry from `.claude/project.json` as its own `- ` line, word
for word; empty when unset).

Then re-run the gate. Repeat to a maximum of **3 iterations, shared across Stage
5's gates** (Stage 5.7/5.8 has its own separate budget).

**Red-check a regression guard.** When the fix loop (or its fix agent) adds or accepts a test as
the guard for a fix, that test only counts if it **fails with the fix reverted** — a guard that
passes either way proves nothing and will be trusted later. You, the orchestrator, run this; never
a dispatched sub-agent. Revert the fix in the working tree by re-applying the inverse edit (no git
writes — no stash, checkout, or restore), run that one test, and confirm it fails for the expected
reason, not a collateral error. Then restore the fix and confirm it passes. If it passes with the
fix reverted, the guard is weak: rewrite it and red-check again. Treat a guard as weak when it:

- asserts only on mocks it set up itself;
- asserts only that no exception was raised;
- compares to a snapshot regenerated with the fix in place;
- never imports or exercises the changed code;
- is skipped or marked xfail.

**Opt-in last-try escalation (`pipeline.fix_loop.escalate_last`, default `false`).** When true,
only the **final** iteration of this budget dispatches its fix agent at
`min(stage_tier + 1, effective_cap)` on the `haiku < sonnet < opus` ladder, and prints
`model: <tier> (cap: <cap>, escalated)` in place of the ordinary dispatch line. Under
`models.cap: "sonnet"`, `min(sonnet + 1, sonnet)` is a no-op — nothing changes. With no cap
(the default) or `models.cap: "opus"`, iterations 1–2 dispatch at `models.fix` (Sonnet default —
a cap only ever lowers a dispatch) and the last iteration dispatches at Opus. Without this key, every retry stays on the same tier by
design — a fix loop is not a place to guess your way up the ladder silently. Excluded entirely
from Stage 5.7/5.8: that stage has its own separate budget and Axis 2 (`models.code_review`) is
not on this ladder, so there is nothing to escalate. `scripts/hooks/enforce-model-cap.sh` needs
no change for this — an escalation that stays within the cap is never rewritten.

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

