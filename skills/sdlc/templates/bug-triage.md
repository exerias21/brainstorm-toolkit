# Bug triage

Loaded at Stage 0 only when a taken or resolved row carries `_bug_`. Severity is the row's
`(P0)`-`(P3)` priority; a P0/P1 bug is triaged first. Do this **before** Stage 2 and write the
verdict per bug into `run.json.data.bug_triage[]` (`row`, `verdict`, `filed`).

## 1. Classify each bug row

- **FIXABLE** — the cause and the correct behaviour are both determinable from the code, the
  tests and the repo's docs.
- **NEEDS-A-HUMAN** — the fix turns on data you cannot see, a fact only a person knows, a product
  decision, a schema change, legal or customer-facing copy, spend, or a credential. You will be
  tempted to guess the missing input and ship a plausible fix; a guess here becomes the bug's
  next, harder-to-find form.

## 2. Split, never block

A bug is often both. Fix the fixable half in this run and file the human half as its own row
rather than stalling the run or silently dropping it. Append the row to `TASKS.md` (under `pipeline.tasks.writer: "orchestrator"`, to `tasks_report.add` instead) under
`Active / Pending` with the same priority, a title naming the decision or input needed, and
` — _manual_` in the trailer (the em-dash separator the row parser reads) (add `_followup: <why>_` when the fixable half is staying open
too). The scope gate never takes a `_manual_` row, so it surfaces as "needs you" instead of
being executed. Link the parent row in the new row's text. A wholly NEEDS-A-HUMAN row is not
executed: leave it `Active / Pending`, report it, and move on.

## 3. MITIGATED is a valid outcome

When the root cause is NEEDS-A-HUMAN but the symptom can be contained safely (a guard, clamp,
validation, or log line), ship the containment and file the root cause as a `_manual_` row per
section 2. Record it in the hand-off as `MITIGATED: <symptom contained by ...>; root cause
filed as <row title>`. Never report MITIGATED as fixed, and never close the original `_bug_`
row for it: the filed root-cause row is what keeps the bug open. Stage 6 closes rows mechanically,
so before it runs: set the original row back from `[~]` to `[ ]` (plan close-out only closes
`[~]` rows; skip this under `writer: "orchestrator"`, which marks none), and remove its entry from `run.json.data.tasks.resolved[]` (a task-id or range
close-out closes every row listed there, whatever its state).

## 4. Verify by effect

A passing test alone does not show the bug is gone. Before changing code, reproduce the
reported symptom (command, request, or failing input) and capture what you saw; after the fix,
re-run the same reproduction and show the symptom absent. If it cannot be reproduced, say so in
the hand-off and downgrade the verdict to unverified. The regression test that guards the fix
is red-checked per `skills/sdlc/templates/fix-loop.md` ("Red-check a regression guard"); a
test that passes with the fix reverted does not count, however green it is.
