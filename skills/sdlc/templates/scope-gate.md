# Scope gate (plan-file runs only)

Loaded from `/sdlc` Stage 0 immediately after `parse.json` is written, for **plan-file inputs
only**. Decides how much of the plan to take **this run**. Task id / range / ad-hoc / `--queue`
inputs never reach this file — each is already bounded to one row or an explicit range — and
neither does `--no-scope-gate`, which forces whole-plan execution (`taken` = every open row).

## Compute size

Compute size from `parse.json` (`implementation_step_count`, `files_to_change`) plus surfaces
touched (**via `skills/sdlc/templates/changed-files-gate.md`**) — the same quantities
`skills/brainstorm/SKILL.md`'s `plan size: <n> steps across <m> files, <k> surface(s)` line
already computes at authoring time. Reuse that verdict rather than re-deriving a second one.

## Zero rows

Stage 0 already read this plan's rows via `scripts/close-tasks.sh rows --plan <slug>
--plan-file <path>` (see Stage 0's plan-file branch — never `reconcile | grep <slug>`,
which only sees *existing* pipeline envelopes and always reports zero rows on a first run
for a plan even when correctly-tagged rows are open). A plan whose `rows` call returned no
`matched[]` (an ad-hoc plan run before rows were appended, or one authored with no rows at
all) falls back to the plan's own `#### Phase N` headings: take the lowest-numbered phase not
itself marked `DEFERRED` or `EXTERNAL`. Say so in the verdict — rows were absent, not skipped
over.

## Phase selection

Phase selection reads its row set from that same `rows` call — each `matched[]` entry already
carries `state`/`phase`/`followup`/`manual`, so no second row scan is needed here.

- **Prefer the plan's own `#### Phase N` boundaries over an arbitrary cut.** If the plan
  declares phases, take the lowest-numbered phase with open (`[ ]`/`[~]`) rows and park every
  later phase whole — **never split a sequentially-dependent chain to hit a number** (the same
  rule `/brainstorm` Step 7.5 states at authoring time; this is its Stage-0 enforcement, not a
  restatement). Fall back to a step-count cut — `pipeline.scope.max_steps_per_run` (default
  `8`) — only when the plan has no phases.
- **Honor an explicit DEFERRED marker.** A phase the plan itself marks deferred (e.g. "cannot
  be verified on this machine") is never pulled into scope, regardless of position.
- **`_manual_` rows are never taken.** They are never marked `[~]` and never counted toward a
  phase's open-row total for scope purposes. A phase whose only open rows are `_manual_` is
  **reported, not taken** — list its row titles in the verdict as `needs you: <titles>`.

## Reconcile check (warn-only, this plan's own cross-store check)

Before taking, run `scripts/close-tasks.sh reconcile --file TASKS.md` and narrow its `drift[]`
to entries that reference this plan (row or envelope candidates matching the plan's file path or
slug). **Warn-only, never blocking**: fold any findings into the verdict line, then proceed —
the same push-back-then-proceed rule as everywhere else in this gate. This is what makes cross-
store drift (a terminal envelope claiming a phase whose rows are still open, or a row's
`_phase:` tag naming a phase the plan doesn't have) visible before this run adds more to it,
without ever deadlocking on it.

## Push back visibly, then proceed — never stop and ask

A blocking prompt deadlocks background/CI runs (`changed-files-gate.md`'s proceed-and-document
precedent is the same call here). Print the verdict as one line, **always, even under `quiet`**:

`scope gate: N steps across M files, K surface(s) — taking phase P (S steps); parking
[phases ...] (deferred: [...]) — resume: <cmd>`

Append whichever of these apply, in order, after the base line above:
- rows absent (see **Zero rows**): ` (no rows — phase from plan headings)`
- one or more `_manual_`-only phases were reported rather than taken: ` needs you: <titles>`
- the reconcile check found anything: ` reconcile: <N> finding(s) — <one-line summary>`

Record `run.json.data.scope_gate = {plan_total_steps, plan_phases, taken, taken_phases, parked,
deferred, why, resume}` — full field-by-field contract in
`skills/sdlc/templates/state-schema.md`. **Mark `[~]` only on the `TASKS.md` rows actually
taken** — parked rows, and every `_manual_` row, stay `Active / Pending`, untouched, so a plain
re-run of `/sdlc <plan>` (the `resume` value) picks up the next phase.

**Accumulate `taken_phases`.** A re-run of `/sdlc <plan>` reuses the plan's slug, so it
overwrites the same `.claude/pipeline/<slug>/run.json` the prior run wrote — the prior run's own
envelope does not survive to be read back later (the `flow-gap-fixes` Phase 2 envelope is
already gone). **Before writing**, if that envelope file still exists on disk and already carries
a `data.scope_gate.taken_phases`, union this run's newly-taken phase(s) into it rather than
overwriting — otherwise a second-phase run forgets the first phase was already taken.

## Park protocol

**On a partial take**, follow the shared **`## Park protocol`** in
`skills/sdlc/templates/queue-mode.md` with `<resume-cmd>` = the `resume` value recorded above —
the same sentinel mechanics the queue loop uses between items, not a second implementation.
