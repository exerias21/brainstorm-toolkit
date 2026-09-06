---
name: flowsim
description: >
  Trace the claimed flow from a plan or task through the source code and report
  mismatches. This is a structured code-review pass formatted as a narrative
  execution trace — the goal is to surface "the plan said X but the code does Y"
  gaps that test suites and evals miss. Use during the /sdlc fix loop, after
  implementing a feature, or ad hoc when a plan and its implementation feel
  misaligned. Invoke via /flowsim or when the user says "trace the flow",
  "verify the plan matches", "walk through what actually happens".
argument-hint: "<plan-file-or-task-ref> [--max-hops N] [--focus <module>] [--force]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# Flowsim — plan vs. implementation flow verification

## Framing

This is NOT a program simulator. It's a **structured code review** formatted as a narrative trace: "the plan claims X → grep/read the code → report what actually happens". Flowsim keeps the scope tight on purpose.

## Inputs

Also called inline by `/sdlc` Stage 5 (as its flow axis) whenever a parent plan
is available.

- **Plan source**: a `plans/brainstorm-<slug>.md` file, a `plans/tasks/task-N-<slug>.md` file, or a TASKS.md row. The plan must describe at least one flow: entry point → steps → outcome.
- **Optional**: `--max-hops N` (default 3) — how many function/module jumps to follow per flow.
- **Optional**: `--focus <module>` — restrict tracing to one module (useful for large features).
- **Optional**: `--force` — ignore the prior-run cache (see Flow step 0) and re-trace every flow.
- **Optional signal**: latest test results as corroborating evidence. Two sources, either counts:
  - eval results at `<eval.features_dir>/<feature>/results.json` (script/eval-runner features), and/or
  - **`test.unit` results** (app-package features whose coverage was routed to the project's native unit suite — see `/sdlc` Stage 3). A passing unit test exercising a traced flow corroborates it; a failing one is a pre-existing mismatch.
  Flowsim degrades to mostly-grep **only when neither source exists** — having unit results (not just eval results) keeps the trace meaningful for the common app-code feature.

## Flow

### 0. Check the prior-run cache

Before tracing, look for `plans/flowsim-<feature-slug>.json` from a previous run.
If it exists and `--force` was NOT passed:

1. Load the prior flows array.
2. For each prior flow with `status: "MATCH"` and every step anchored to a real
   `file:line`, check whether any of those anchor files have been modified since
   the cache was written (compare cache file mtime against each anchor file's mtime).
3. **If no anchor files have changed**: mark that flow as `cached-MATCH` and skip
   re-tracing it in step 2. It carries through to the report unchanged.
4. **If any anchor file has changed, or the flow had any non-MATCH status**:
   re-trace from scratch in step 2.

This trims re-runs after a fix loop — flows whose code paths were not touched
by the fix do not need to be re-walked.

If `plans/flowsim-<feature-slug>.json` does not exist, proceed normally — no
cache, every flow is traced fresh.

### 1. Extract claimed flows

From the plan, identify each distinct **flow** — a user/system action and its claimed path.
List each flow as a numbered item. Stop here and ask the user to confirm if the plan is vague enough that you'd be guessing at the flows — do not invent flows that the plan didn't claim.

### 2. Trace each flow through the code

Skip any flow marked `cached-MATCH` in step 0 — its prior trace is reused as-is.
For every other flow, walk through up to `--max-hops` steps. At each hop, record:
- **Claimed step**: what the plan says happens.
- **Code anchor**: file path + line number + function/symbol name. Found via grep/read.
- **Actual behavior**: one sentence on what the code does at that anchor.
- **Status**: `MATCH` / `MISMATCH` / `UNCLEAR` / `MISSING`.

Rules:
- **Every anchor must be a real `file:line` reference.** If you can't find one, mark `MISSING`.
- **Follow the actual call chain**, not what the plan hopes for. If the plan says A→B→C but the code does A→D→C, report A→D→C and flag `MISMATCH` at step 2.
- **Stop at `--max-hops`** even if the chain continues. Note this as "truncated at hop N — continue manually if needed".

### 3. Cross-reference with evals and tests

If `.claude/project.json` has `eval.features_dir` and results exist for this feature:
- A passing eval that exercises the traced flow → note as "corroborated by eval `<name>`".
- A failing eval → flag as "pre-existing failure: `<test>` — may indicate the `MISMATCH` is known".
- No eval for this flow → note "no eval coverage for this flow".

Also check the `test.unit` / `test.e2e` config for tests matching the flow's surface (e.g., a POST /api/orders flow should have a route test). Don't re-run them — just note whether they exist.

### 4. Report

Produce a markdown block:

```markdown
## Flowsim: <feature name>

### Flow 1: <one-line description>

| # | Claimed | Anchor | Actual | Status |
|---|---------|--------|--------|--------|
| 2 | Validates payload via OrderSchema | `api/schemas/order.py:10` `OrderSchema` | Schema exists but missing `payment_method` field | **MISMATCH** |

**Summary**: Flow 1 deviates from the plan at step 2, corroborated by a failing eval.

### Flow 2: ...
```

## Output limits

- **Three hops max by default.** If the plan implies a 5-hop flow, split it into two flows of 3 hops each.
- **Don't fix anything.** Flowsim is read-only. Hand findings to the user (or, when running inside the pipeline, to Stage 5's fix loop).
- **Cap output at ~60 lines of markdown** unless there are many flows. A 200-line flowsim report is a sign the plan is too ambitious for one feature.
