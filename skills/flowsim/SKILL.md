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
  brainstorm-toolkit-applies-to: claude copilot
---

# Flowsim — plan vs. implementation flow verification

## Framing

This is NOT a program simulator. It's a **structured code review** formatted as a narrative trace: "the plan claims X → grep/read the code → report what actually happens". LLMs are reliable at static analysis ("does this call exist", "what does this function return") when scoped to 2–3 hops. Flowsim keeps the scope tight on purpose.

## When to use

- User invokes `/flowsim <plan-file>` or `/flowsim task-3-add-orders`
- Called automatically by `/sdlc` Stage 5.6 (unless `--skip-flowsim` is set)
- User asks "does the plan actually match what we built?", "trace this flow", "walk through what happens when a user X"

## Inputs

- **Plan source**: a `plans/brainstorm-<slug>.md` file, a `plans/tasks/task-N-<slug>.md` file, or a TASKS.md row. The plan must describe at least one flow: entry point → steps → outcome.
- **Optional**: `--max-hops N` (default 3) — how many function/module jumps to follow per flow.
- **Optional**: `--focus <module>` — restrict tracing to one module (useful for large features).
- **Optional**: `--force` — ignore the prior-run cache (see Flow step 0) and re-trace every flow.
- **Optional signal**: latest eval results at `<eval.features_dir>/<feature>/results.json` if present. Flowsim reads these and factors them into the report (a passing eval for a flow is corroborating evidence; a failing eval is a pre-existing mismatch).

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
by the fix do not need to be re-walked. Typical savings: 40–60% of trace work
on subsequent runs of `/sdlc` Stage 5.6 against the same feature.

If `plans/flowsim-<feature-slug>.json` does not exist, proceed normally — no
cache, every flow is traced fresh.

### 1. Extract claimed flows

From the plan, identify each distinct **flow** — a user/system action and its claimed path. Examples:
- "User submits order form → POST /api/orders → OrderService.create → Stripe.charge → db.orders.insert"
- "Cron runs → worker/discovery.py → fetch(source_url) → parse → upsert into `deals` table"
- "User clicks 'Export' → GET /api/reports/export.csv → stream assembled from db"

List each flow as a numbered item. Stop here and ask the user to confirm if the plan is vague enough that you'd be guessing at the flows — do not invent flows that the plan didn't claim.

### 2. Trace each flow through the code

Skip any flow marked `cached-MATCH` in step 0 — its prior trace is reused as-is.
For every other flow, walk through up to `--max-hops` steps. At each hop, record:
- **Claimed step**: what the plan says happens.
- **Code anchor**: file path + line number + function/symbol name. Found via grep/read.
- **Actual behavior**: one sentence on what the code does at that anchor.
- **Status**: `MATCH` / `MISMATCH` / `UNCLEAR` / `MISSING`.

Rules:
- **Every anchor must be a real `file:line` reference.** If you can't find one, mark `MISSING` — do not hallucinate.
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
| 1 | User POSTs /api/orders | `api/routes/orders.py:42` `create_order()` | Matches | MATCH |
| 2 | Validates payload via OrderSchema | `api/schemas/order.py:10` `OrderSchema` | Schema exists but missing `payment_method` field | **MISMATCH** |
| 3 | OrderService.create | (MISSING) | No `OrderService` class found; inline logic in route handler | **MISMATCH** |

**Eval coverage**: `evals/orders/` has 3 fixtures, 2 pass, 1 fail (`missing-payment-method.json`).
**Test coverage**: `tests/test_orders.py` exists with 4 cases; none exercise Flow 1 end-to-end.

**Summary**: Flow 1 deviates from the plan at steps 2 and 3. Step 2 mismatch is corroborated by a failing eval. Step 3 suggests the plan's service-layer separation was not implemented.

### Flow 2: ...
```

### 5. Emit structured output for /sdlc

If invoked by `/sdlc`, also write a machine-readable summary to `plans/flowsim-<feature-slug>.json`:

```json
{
  "feature": "add-orders",
  "flows": [
    {
      "id": 1,
      "description": "User submits order form",
      "status": "MISMATCH",
      "mismatches": [
        {"step": 2, "anchor": "api/schemas/order.py:10", "detail": "Schema missing payment_method field"},
        {"step": 3, "anchor": null, "detail": "OrderService class not found; logic inline in route"}
      ]
    }
  ]
}
```

This lets `/sdlc` feed findings into the Stage 4 fix loop without re-parsing the markdown.

## Rules

- **Three hops max by default.** Deeper chains get unreliable; if the plan implies a 5-hop flow, split it into two flows of 3 hops each.
- **Every claim needs a `file:line` anchor** or an explicit `MISSING` marker. No "I think this is in the code somewhere".
- **Don't invent flows the plan didn't claim.** If the plan is vague, say so and ask the user to clarify before tracing.
- **Don't fix anything.** Flowsim is read-only. Handing fixes off to `/sdlc`'s fix loop or the user is the correct move.
- **Cap output at ~60 lines of markdown** unless there are many flows. A 200-line flowsim report is a sign the plan is too ambitious for one feature.
