---
name: triage
description: >
  The red-path fix recommender — turns a PAUSED/failed pipeline run into a concrete next
  action instead of a "fix manually" apology. Reads the paused envelope + its failing stage
  sidecar, classifies the failure (flaky · code-defect · plan-wrong · config-missing ·
  abandoned), and recommends ONE command — drafting the fix for a real code defect — with an
  executable `--resume` re-entry that reuses the run's green stages. Read-only by default;
  `--go` opt-in. Invoke via /triage [<slug>], or when a pipeline paused and the user asks
  "why did it stop / what do I do?". The on-demand sibling of `/next` rung 1 and the
  green-path Review→Fix stage.
argument-hint: "[<slug>] [--go]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Triage — turn a paused run into a next action

The pipeline already wrote machine-readable failure evidence to disk; `/triage` reads it and
hands you a diagnosis + one command, instead of a prose apology. Read-only unless `--go`.

## Step 0 — Resolve the run

- `<slug>` given → triage `.claude/pipeline/<slug>/`.
- Omitted → the **most-recently-updated non-terminal run on the current branch** (same
  selection rule `/next` and continuity detection use). If none exists, say so and stop
  ("no paused/failed run on this branch — `/status` for the queue").

Read `run.json` (`pipeline`, `stage`, `status`, `base_commit`, `plan_hash`) and the failing
stage's sidecar (`eval-fix.json`, `plan-validate.json`, `plans/flowsim-<slug>.json`,
`implement-<lane>.json`, …). This is a single **Sonnet/session-tier read job** — not a
fan-out, no `capModel` plumbing.

## Step 1 — Classify the failure

Bucket it from the sidecar evidence (reuse the pipeline's Diagnosis vocabulary — same classes
the pause messages name):

| Class | Signal in the sidecar | Recommended action shape |
|---|---|---|
| **flaky / environmental** | failure not reproducible on a single re-run; e2e flake-guard tripped; log-audit noise | re-run the one gate; if green, `--resume` |
| **code-defect** | eval/test failure with stable expected-vs-actual | **draft a fix** (below) → `/task`, then `--resume` |
| **plan-wrong** | flowsim MISMATCH where the code is defensible; Stage 1.5 critical; UNCLEAR markers | drafted plan edit → `/brainstorm` the section, then a **fresh** run (not `--resume` — the plan hash changes) |
| **config-missing** | "no `eval.runner`", missing env var, unapplied migration | the one-line setup command, then `--resume` |
| **abandoned** | work landed outside the pipeline (`base_commit` ancestor of HEAD, tree clean) | close the envelope: `/status --prune-stale` |

## Step 2 — Recommend ONE action (draft the fix for code defects)

Output in `/next`'s shape — one command, one rationale, ≤2 alternatives. For a **code-defect**,
*draft* the fix rather than making the user compose it (same auto-draft + one-tap-confirm
discipline the gotcha flywheel uses): a `REVIEW_FINDING`-shaped object
(`{severity, file, line, defect, failure_scenario, fix, auto_fixable}`, sourced from the
sidecar evidence rather than a reviewer lens) surfaced as a ready-to-run
`/task fix: <drafted description>`.

Apply the **`auto_fixable` rubric verbatim** (from `docs/REVIEW-FIX-STAGE.md`): a concrete,
reproducible failure with an explicit contract (the failing eval *is* the contract) →
`auto_fixable: true`. "plan-wrong" and anything touching a **user-observable default** →
a **design decision**: surface it, never auto-fix — the human decides. Triage v1 is
**recommend-only**; an actual fix loop is the v2 opt-up.

## Step 3 — Executable re-entry

Every recommendation ends in a command that *works today* — never `re-run from scratch`:

```
Next: /task fix: eval test_radius_refetch expects 200 but Stage 4 got 500 on empty-body POST
Why:  eval-fix.json → stable code-defect (expected 200, actual 500) in api/radius.py:88; auto_fixable.
Also: after the fix, /sdlc plans/brainstorm-radius-refetch.md --resume (reuses the 3 green stages)
```

The `--resume` (shipped in L5) is what makes triage worth running: it resumes at the first
non-passing stage instead of re-spending — and overwriting — the evidence you just read.
Use a **fresh** run only for the plan-wrong class (editing the plan changes its `plan_hash`,
which `--resume` rejects by design).

## `--go` — execute the top recommendation

Run it instead of printing, with the toolkit's safety asymmetry: a drafted `/task`, a gate
re-run, or `/status --prune-stale` may proceed; anything that writes git history confirms
first. A **design-decision** finding is never auto-run — it is surfaced for the human.

## Rules

- **Pure read by default** (`--go` is the sole write path, and it keeps each recommended
  command's own confirm gate). Triage never deletes the `.next-action` sentinel.
- One paused run, one recommendation — for the full queue that's `/status`; for "what next"
  across everything that's `/next` (whose rung 1 routes paused runs here).
- No independent reviewer model — triage reads objective failure evidence, it doesn't
  adversarially second-guess green code. Session/Sonnet tier is right.
