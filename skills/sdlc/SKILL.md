---
name: sdlc
description: >
  Automated plan-to-PR pipeline. Takes a plan file, implements it via agent,
  generates evals, runs eval+fix loop, validates with /test-check, and creates
  a PR for human review. The full SDLC lifecycle minus human merge.
argument-hint: "{plan_file} [--resume]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# SDLC Pipeline

Autonomous feature delivery: plan file in, PR out.

```
/brainstorm → plan → /sdlc → sanity-check → implement → eval → fix → validate → flowsim → PR → human review
```

## Arguments

- `plan_file` (required): Path to the plan (e.g., `plans/my-feature.md`)
- `--resume` (optional): resume a paused/failed prior run for this plan's slug
  instead of starting fresh — skips stages whose sidecar already shows
  `status: "pass"` and picks up at the first non-passing stage, reusing the
  evidence the prior run wrote. See **Resumption** below. Forces the prose path.
- `--model <tier>` (optional): per-run fan-out cap override; see **Model cap**
  and [`templates/models.md`](templates/models.md). `tier` ∈
  `haiku|sonnet|opus`. **Not an alias for `--review-model`** — `--model fable`
  is an unrecognized value for this flag (per `models.md`'s invalid-input
  rule: ignore, warn once, fall through to `models.cap`/default) and must
  resolve to the configured cap *before* it is ever passed as `args.model_cap`
  — never forward the raw typo'd string, since forwarding it un-caps every
- `--review-model <name>` (optional): per-run reviewer-model override; see
  **Reviewer model** and [`templates/models.md`](templates/models.md).
  `name` ∈ `fable|opus|sonnet|haiku`. Default `opus`. Passing `fable` (or
  setting `models.code_review: "fable"`) is a valid, explicit,
  cost-aware opt-in — usage-billed since Claude Fable 5's 2026-07-07
  promotional-access sunset — never the default.
- `--no-review` (optional): fully skip Stage 5.7/5.8 for this run. **Note:**
  Stage 5.7/5.8 is opt-in, permanently — it does not run at all unless
  `--review-model` is passed or `pipeline.review_fix.enabled: true` is set, so
  `--no-review` is mainly useful to override an opted-in `project.json` for a
  single run.

Skill-repo mode is auto-detected — see "Skill-repo mode" below. To preview a
plan before running the pipeline, use `/brainstorm`.

## Prerequisites

- Plan file must exist and contain implementation steps
- Git working tree must be clean (no uncommitted changes) — **except with
  `--resume`**, which tolerates a dirty tree on purpose: a manual fix applied
  between the pause and the resume is the normal case (the code-defect diagnosis
  literally tells you to `/task fix:` then resume), and `/sdlc-lite` hands you a
  dirty tree by design.
- `.claude/project.json` exists with at least `main_branch`; `test.*`, `logs.*`,
  and `eval.*` are recommended so Stages 4-5 work. Missing config just causes
  those stages to skip, not fail.

---

## State envelope

Each `/sdlc` run writes a transparent state journal under
`.claude/pipeline/<feature-slug>/`. Schema and per-stage `data` shapes are
documented in `templates/state-schema.md` (read once before implementing
sidecar writes).

```
.claude/pipeline/<feature-slug>/
  run.json                     # top-level run record (stage, status, args, hashes)
  stage-outputs/<stage>.json   # one sidecar per completed stage
```

**Behavior**:
- At Stage 1 — **unless `--resume` was passed** (then follow **Resumption** below:
  read the existing `run.json`, don't overwrite it) — `mkdir -p
  .claude/pipeline/<slug>/stage-outputs/` and write initial `run.json` with
  `{schema_version: 1, pipeline: "sdlc", stage: "parse", status: "in_progress",
  started_at, updated_at, plan_hash, base_commit, args}`. **Compute the three that
  get dropped when left abstract** (DQ6): `plan_hash: "sha256:$(sha256sum <plan> | cut -d' ' -f1)"`,
  `started_at` = `updated_at` = `"$(date -u +%Y-%m-%dT%H:%M:%SZ)"`. Capture `base_commit` =
  `git rev-parse HEAD` (the commit you're building on, before any pipeline
  commit). **Omitting `plan_hash`/`started_at`/`updated_at` silently breaks `--resume`
  and `/status`/`/repo-health` staleness detection — always write them.** Under `--resume`, the envelope already exists — set
  `run.json.status = "in_progress"` and resume at the first non-passing stage
  instead of re-initializing.
- On every stage transition, update `run.json.stage` and `run.json.updated_at`.
- When a stage finishes, write `stage-outputs/<stage>.json` per the schema
  (canonical kebab name from `docs/CONVENTIONS.md`, never decimals — so
  `sanity-check.json`, not `stage-1.5.json`) and append the stage to
  `run.json.stages_completed`.
- When skill-repo mode is auto-detected, skipped stages (`generate-evals`,
  `flowsim`) write **no sidecar**; add their
  names to `run.json.stages_skipped` instead.
- On terminal state, set `run.json.status` to `complete`, `failed`, or `paused`
  per the schema doc.

**Best-effort writes**: if any state write fails (disk full, permissions,
read-only volume), log a single-line warning to stderr
(`[state-envelope] write failed: <error>; continuing`) and proceed.
**State writes never fail a pipeline run.** A consumer that never reads these
files sees no behavior change.

A fresh `/sdlc <plan>` invocation (no `--resume`) **overwrites** any prior
`run.json` and `stage-outputs/` for the same slug — resumption is opt-in via
`--resume` (see **Resumption** below), never automatic.

### Resumption (`--resume`)

`/sdlc <plan> --resume` picks up a paused/failed prior run instead of restarting
from Stage 1 — which would both re-spend every green stage and **overwrite the
failure evidence you're resuming to fix**. Behavior:

1. Read `.claude/pipeline/<slug>/run.json` (slug derived from the plan file
   exactly as Stage 1 does it). **If absent** → error: "no prior run for
   `<slug>` — run `/sdlc <plan>` without `--resume` to start fresh." Do not
   create a fresh run under `--resume`.
2. **Staleness guard.** If `run.json.plan_hash` ≠ the current plan file's hash,
   the plan changed since the paused run — **reject**: "plan `<slug>` changed
   since the paused run; start fresh (`/sdlc <plan>`) or revert the plan." Don't
   try to reconcile. (Optional/additive: a per-stage `prompt_hash` mismatch —
   the *toolkit* changed a stage's prompt since the run — may *warn* rather than
   reject; skip the check entirely when the field is absent.)
3. Determine the resume point: every stage whose `stage-outputs/<stage>.json`
   shows `status: "pass"` (equivalently, every name already in
   `run.json.stages_completed`) is **skipped and its output reused**. Resume at
   the first non-passing stage — normally the one `run.json.stage` names / the
   one that paused.
4. If a reused stage-output references a file that no longer exists (e.g. the
   plan was edited to remove a step) → reject with a clear error; don't be
   clever.
5. If the paused stage no longer exists in the current pipeline (a toolkit
   upgrade split it) → "stage `<old>` no longer in pipeline — start fresh." (A
   `--resume-from <stage>` override is a possible future addition; not v1.)
6. From the resume point onward, behave **identically to a fresh run** — same
   gates, same **shared 3-iteration fix budget** (it starts fresh for the
   resumed stages), same envelope updates; set `run.json.status = "in_progress"`
   on pickup.

Resume reads the prior sidecars off disk
(see the execution-mode note above), so `--resume` always runs these prose stages.

### Continuity detection (prompt, never auto)

At Stage 1, before initializing this run, check whether the **current branch**
has an in-flight or just-completed pipeline run you might be continuing or
silently skipping. **Do not scan every envelope for "ancestor of HEAD"** — after
a run merges, its `base_commit` is an ancestor of HEAD essentially forever, so
that test fires on every historical run (a false-positive storm). Instead:

0. **If the current branch IS the main branch** (`main_branch` from
   `.claude/project.json`, default `main`) → **skip continuity detection
   entirely.** Main accumulates merges; every merged run's `base_commit` is an
   ancestor and its commit is behind HEAD, so the check is pure noise there.
   Continuation is a *feature-branch* concern. This guard and the two below are
   the shared scan in `skills/sdlc/templates/envelope-staleness.md` — the same
   procedure `/status`, `/repo-health` and `/status` run. Keep them in sync there,
   not here; they drifted once already.
1. Otherwise (a feature branch): glob `.claude/pipeline/*/run.json`; keep only
   runs whose `base_commit` is an ancestor of HEAD (`git merge-base --is-ancestor`).
2. Of those, take the **single most-recently-updated** run (`updated_at`). One
   prompt at most — never one per historical run.
3. Prompt **only** if that latest run is either:
   - **non-terminal** (`status` in_progress/paused) — an open run you're
     building past (also the orphan/stale case); or
   - **complete but HEAD has advanced past its final commit** — i.e. follow-up
     work landed *after* the last pipeline run (compare HEAD to the run's
     recorded `commit_sha` from `pr-create.json`/`handoff.json`; if they differ,
     this follow-up didn't go through the pipeline).
   If the latest run is complete and HEAD still equals its final commit, stay
   silent — nothing new happened, nothing to flag.

```
This branch's last pipeline run was /<pipeline> for '<slug>' (<short-sha>,
<n> commits back, status <status>). Continue that flow, inspect its run.json,
or start fresh?
```

This keeps `/sdlc` zero-flag (a prompt, not a flag) and catches the real gap —
a follow-up that landed outside the pipeline — without nagging about every
merged run in history.

### Skill-repo mode detection

At Stage 1, before doing anything else, check whether the repo is itself a
markdown-skill plugin: if `.claude-plugin/marketplace.json` exists at repo
root, switch to skill-repo stage substitutions for the rest of the run (see
"Skill-repo mode" below). No flag is needed; detection is automatic.

**Vendored-skill guard:** if `.claude-plugin/marketplace.json` is **absent**
(this is an ordinary consumer repo) but the plan's changed files target
`.claude/skills/**`, `.github/skills/**`, or `.agents/skills/**` — i.e. it
edits *installed/vendored* skill copies — **stop and report.** Those edits
belong upstream in the canonical brainstorm-toolkit repo, then get
re-installed; shipping them through a consumer's pipeline diverges the vendored
copy from canonical. Don't run the pipeline on vendored skill edits.

---

## Stage 1: Parse Plan

**If `--resume` was passed**, do not initialize a fresh envelope — follow
**Resumption** (above): read the existing `run.json`, reject on a `plan_hash`
mismatch, and resume at the first stage whose sidecar isn't `status: "pass"`
(skip `parse` if it already passed).

Read the plan file and extract structured information:

1. **Read** the plan file fully. The plan source can be:
   - A standard brainstorm plan (e.g., `plans/brainstorm-<slug>.md` with Direction / Implementation Steps sections), OR
   - A `TASKS.md`-style checkbox list at repo root — in which case treat every `[ ]` or `[~]` row in the `Active / Pending` section as an implementation step, and follow the `plans/tasks/task-N-<slug>.md` links for detail.
2. **Extract**:
   - Feature name/slug (from filename or first heading; for TASKS.md input, derive from the row text or first linked task file)
   - Implementation steps (numbered lists with file paths, or checkbox rows)
   - Files to create or modify (look for file paths, table of files, or each linked task file's `files:` frontmatter)
   - Acceptance criteria (look for "expected", "should", "must", "verify" language)
   - Cross-module touchpoints
3. **Determine** the feature slug for branch naming and eval registration
4. **Report** the plan scope:

```markdown
## SDLC Pipeline — {feature_name}

**Plan**: {plan_file}
**Files to change**: {count} ({list})
**Implementation steps**: {count}
**Acceptance criteria**: {count} identified
**Estimated complexity**: Small / Medium / Large
```

**State write**: write `stage-outputs/parse.json` with `data.feature_name`,
`data.files_to_change`, `data.implementation_step_count`,
`data.acceptance_criteria_count`. Append `parse` to `run.json.stages_completed`.

---

## Model cap (all sub-agent dispatches)

Every agent this pipeline dispatches — the sanity Haikus, the Opus-tier
implementer (Sonnet by default once the cap applies), the decompose lanes, the
fix agent, the validators — honors the **model-tier cap**. Resolve each dispatch's tier per
[`templates/models.md`](templates/models.md): `--model <tier>` flag >
`project.json` `models.cap` > the tier named at the site. **Before each
dispatch, print `model: <tier> (cap: <cap|none>)`** and dispatch at that tier.
**The default is Sonnet-first**: with no `--model`/`models.cap` set the fan-out
resolves to Sonnet (Opus sites → Sonnet, Haiku stays Haiku); `--model opus` opts
a run up to Opus. Emit the session-model nudge once when a cap is active. Prose is the only enforcement
surface — print the line, then dispatch at that tier.

**Config-presence check (once, at Stage 1).** If `.claude/project.json` is **absent** while
`.claude/project.json.example` is **present**, warn once — every `project.json`-gated setting in
this repo, `models.cap` included, is silently inert and the run is about to report `cap: none`:

```
config: .claude/project.json.example exists but project.json does not — no project config is
        being read (models.cap, pipeline.*, test commands). Copy the example to activate it.
```

## Output verbosity (default: quiet)

**Default `quiet`.** Stage narration is re-read by every later turn in the same session, so it
compounds — an audited run averaged 468k context across 5,321 orchestrator turns, and narration is
the cheapest part of that to give up. Detail is not lost: every stage already writes its sidecar
under `.claude/pipeline/<slug>/stage-outputs/`, which is the durable record.

Under `quiet`, each stage prints **one** line and nothing else:

```
<stage> · <verdict> · model: <tier> (cap: <cap|none>)
```

and the run closes with a single summary table at Stage 7. Do not narrate intermediate reasoning,
restate file contents, echo sub-agent output, or recap what a stage is about to do.

**Always printed, even under `quiet`** — these are the run's contract, not narration:

- the per-dispatch `model: <tier> (cap: <cap|none>)` line (the cap is only as real as this
  line — `validate_skills.py` soft-warns that a fan-out skill *references* `model-cap.md`, it does
  NOT check that the line is printed, so nothing but this instruction enforces it),
- every gate verdict and any PAUSE/soft-stop block,
- the `Next:` seam line,
- warnings: the config-presence check above, the reviewer-axis cost note, the session-model nudge.

Set `pipeline.output.verbosity: "normal"` in `.claude/project.json` to restore full narration.
Read with graceful-skip — a missing `project.json` means `quiet`, which is the point: the savings
must not depend on a config file that the audited repo never had.

## Stage 1.5: Plan Sanity Check

Before spending implementation tokens, verify the plan is actually
correct. Launch the configured focus agents **in parallel** (single message) to
check different dimensions. This is cheap insurance — catches wrong file paths,
missing steps, and known gotchas before they become bugs.

Read the prompts from `templates/stage-1.5-sanity-check.md` (sections: `paths`,
`completeness`, `gotchas`). Substitute `{plan_file}` and `{feature_name}`, then
dispatch the selected agents in a single message — one Agent call per section.

**Which focuses run — `agents.sanity_focuses`.** Read the array from
`.claude/project.json`; absent means all three defaults. Setting fewer cuts this stage's
cost roughly linearly (one agent per focus). `paths` is the cheapest and most mechanical
(file existence); `completeness` is the judgment-heavy one; `gotchas` is only useful when
a `GOTCHAS.md` exists. An unrecognized focus name is ignored with one warning.

**Which tier — `models.sanity`.** Built-in default is `haiku` for every
focus. `.claude/project.json` `models.sanity` (`haiku|sonnet|opus`)
**replaces that default for all focuses** when set. Reach for it when this stage is
reviewing *plans* rather than checking paths: `paths` is genuinely mechanical, but
`completeness` is asking "does this plan hang together?", which is the kind of judgment a
stronger reader does better. Raising it costs on **every** run that reaches Stage 1.5 —
which is every run, since the stage is never gated.

The resolved tier still passes through the **model cap** (`models.cap` / `--model`, see
`templates/models.md`), which is a *ceiling*: `capModel(effective_default, cap)`. Note
the consequence, because it is the whole reason this key exists — **the cap can only
lower, so while the site default is `haiku` there is no way to raise this stage at all.**
`models.cap: "opus"` does not raise it; `--model opus` does not raise it. Setting
`sanity_check.model` is the only lever. Once set above `haiku`, the cap applies normally
(a Sonnet-first cap pulls `opus` back to `sonnet` unless you also pass `--model opus`).

This is **not** a new model axis — it sets a default *within* the fan-out axis and is
still capped by it. Print `model: <tier> (cap: <cap|none>)` and the resolved focus list —
`sanity focuses: <a, b, …> (N of 3 defaults)` — before dispatching.

### Processing results

1. Collect all 3 agent reports
2. **If issues found**: auto-patch the plan file with corrections. Log a short
   summary of what was fixed, then proceed to Stage 2 with the corrected plan.
3. **If critical issues** (plan references nonexistent files, entire approach
   is misguided): report to user and **STOP** — the plan needs human revision.
4. **If all clean**: proceed to Stage 2.

**State write**: write `stage-outputs/sanity-check.json` with
`data.agents` (focus, status, issue_count for each), `data.auto_patched`
(bool), and `data.issues`. Status is `pass` if all three agents reported no
issues, `pass` with `auto_patched: true` if issues were auto-corrected,
`paused` if critical issues forced a stop.

---

## Stage 2: Implement

**Delegation is mandatory — during this stage the orchestrator does not call Write or Edit.**
Dispatch the implement agent(s) and take back `git diff --numstat`; file bodies stay in the
agent's context, never yours. This is the pipeline's most expensive rule to break. On an
audited three-day run the orchestrator made **183 Write/Edit calls against 8 dispatches**,
parking ~131k tokens of file content in its own context — the primary driver of the 999k
peak that forced five context resets, and of the finding that 81% of the run's tokens were
orchestrator context rather than the sub-agent fan-out. Sub-agents exist to keep the
exploring out of the joining context; implementing inline throws that away.

Two corollaries:
- If a change is too small to be worth dispatching, it is too small for `/sdlc` — use `/task`.
- Reading a file to *decide* is fine. Writing one is not.

**Open the templates named below rather than recalling them.** A "reuse `<template>`" pointer
that nobody opens resolves to nothing, and that is measurably what happened: across the
audited session, **0 of 135 Read/Glob/Grep calls touched `templates/`**, so this stage's
dispatch instruction never reached the model at all.

**Ground in the live code first.** Whichever path runs below, the implementation
must follow `templates/convention-grounding.md`: the existing code is the source
of truth (not `AGENTS.md` / `CLAUDE.md` — those are hints that may be stale),
reuse the 2–3 closest existing implementations' patterns rather than inventing
parallel ones, and if the plan carries a `## Conventions & reuse` block, honor it
and re-verify it against current code. This directive is baked into the agent
prompts (`stage-2-implement.md`, the decompose/dispatch templates) so it holds on
every path.

Stage 2 is **auto-gated** (zero flags). Small / single-surface plans run the
single implementation agent exactly as before. Large, multi-surface plans
decompose into focused per-lane subagents (2a → 2b → 2c) under this same
orchestrator — the win is **context isolation**, not parallelism. There is one
owner of global consistency throughout: the orchestrator.

### The gate (compute, then route)

Read `stage-outputs/parse.json`. Compute:
1. `surfaces_touched` = the distinct surfaces from `templates/changed-files-gate.md`
   (frontend / backend / data / docs / deploy-delta) that the **planned** files
   in `parse.json.data.files_to_change` match. The gate runs *before* any code
   exists, so apply the surface globs to intended files, not to a diff.
2. `task_count` = `parse.json.data.implementation_step_count`.
3. `DECOMPOSE_MIN_TASKS` — a named constant, **default `6`**, overridable via
   `.claude/project.json` `agents.decompose_min_tasks`.
4. **Disjointness:** classify each planned file by surface; if any file matches
   more than one surface, or every file lands in a single surface, the surfaces
   are not cleanly separable.

**Decompose iff** `surfaces_touched.count >= 2` **AND** `task_count >=
DECOMPOSE_MIN_TASKS` **AND** the per-surface file sets are disjoint. Otherwise →
single-agent fallback. Record the decision **and its inputs** so a reader sees
exactly why it did or didn't fan out (decompose path: `decompose.json`;
single-agent path: the gate summary in `implement.json`). Never a silent choice.

On Stage 2a entry set `run.json.data.stage2_decomposed` (bool) and
`run.json.data.lanes` (lane-name list, or `[]` when not decomposing).

### Single-agent fallback (the default — unchanged behavior)

When the gate says **don't decompose**, run Stage 2 exactly as before: read the
prompt from `templates/stage-2-implement.md`, substitute `{feature_name}` and
`{plan_content}`, dispatch one implement agent — **Sonnet by default** (Opus
only on `--model opus` opt-up); see **Model cap** above. After it completes: review the git
diff summary, verify expected files, and **STOP** + report if it reports
blockers. Write `stage-outputs/implement.json` with `data.agent_model`,
`data.files_changed[]` (path + added/removed from `git diff --numstat`),
`data.total_added`, `data.total_removed`, `data.blockers_reported[]`, and a
`summary` noting the gate inputs that kept it single-agent. Status `pass` on
success, `fail` if blockers. **No decompose/converge sidecars are written.**
Then proceed to Stage 3.

### 2a — Decompose (when the gate fans out)

Read `templates/stage-2a-decompose.md`. Substitute `{feature_name}`,
`{plan_content}`, `{files_to_change}`, `{decompose_min_tasks}`; dispatch one
**Sonnet** decomposer. It classifies files by the gate's surface globs, emits
lanes (each with `files` / `steps` / `depends_on` / `model` / `contract`), writes
a per-lane task file, and returns the JSON. Write `stage-outputs/decompose.json`
with `data.lanes[]` + `data.gate_inputs` + `data.gate_decision`. If it returns a
single lane (`gate_decision: "single-agent"`), fall through to the single-agent
fallback instead.

### 2b — Dispatch (one subagent per lane, sequential)

Read `templates/stage-2b-dispatch.md`. Dispatch lanes **sequentially in
dependency order** (per `depends_on`, default `data → backend → frontend`) — one
subagent at a time, never parallel. Each subagent gets only its task file, its
`{lane_files}`, its `{lane_steps}`, and the `{contract}` (its own seam plus the
contracts of lanes it depends on); model per `decompose.json`. Each writes
`stage-outputs/implement-<lane>.json` (the `implement.json` shape +
`data.lane`). If a lane reports an unresolvable blocker, **STOP** and report.

### 2c — Converge (orchestrator)

Read `templates/stage-2c-converge.md`. After all lanes complete, the
orchestrator resolves cross-lane integration (imports, call sites, shared
types), runs an import / symbol-collision sweep over the union of changed files,
and reconciles any contract violations (small seam fixes here; real logic gaps
go to the shared fix loop). Write `stage-outputs/converge.json` with
`data.merged_files`, `data.integration_fixes`, `data.import_check`,
`data.symbol_collisions`. Append `implement` to `run.json.stages_completed`
**once** (after converge), not per lane. Then proceed to Stage 3.

---

## Stage 3: Generate Evals

Create test cases that verify the plan's INTENT, not just "does it compile."

### For features with new Python functions:

1. Identify all new pure functions (no I/O, no database, no browser)
2. Create `tests/eval/test_{feature_slug}_eval.py` with parameterized test cases
3. Import functions via `tests/eval/conftest.py::load_script_module()`
4. Write binary assertions: expected input → expected output

### For features with new scripts that output JSON:

1. If the script accepts `--input` fixtures, create:
   - `<eval.features_dir>/{feature_slug}/fixtures/{scenario}.json` — input data
   - `<eval.features_dir>/{feature_slug}/expected/{scenario}.json` — expected output
2. The runner auto-discovers new features by scanning `<eval.features_dir>/*/` —
   no registration needed.

### For pure functions that live in the application package (not loadable by the eval harness):

The eval harness is **script-scoped**: `tests/eval/conftest.py::load_script_module()`
only imports files under `scripts/`, and `eval-runner.py` only discovers features
under `<eval.features_dir>/`. Pure functions inside an application package
(`backend/app/...`, `src/...`, a FastAPI/Django/Rails service module) are
**unreachable** by that harness. **Do not mark these "skipped — no testable
surface"** — that's the trap where the most common feature type silently gets
zero coverage.

Instead, when the testable functions live in the app package:
1. Generate tests into the **project's native unit-test suite** at the
   project's convention (where `test.unit` points — e.g. `backend/tests/`,
   `tests/`, `__tests__/`), not into `tests/eval/`.
2. They run in **Stage 5** via the configured `test.unit` command, not via
   `eval.runner`.
3. Record `data.coverage_route: "test.unit"` in the generate-evals sidecar so
   Stage 5's flow axis knows unit results are the corroborating evidence.

### For features without testable pure functions:

1. Create schema validation tests — does the output match the expected JSON structure?
2. Create smoke tests — does the script/endpoint return a valid response?
3. If no tests are possible, note "eval generation skipped — no testable surface" and proceed

### Key principle:

Evals must be created BEFORE running them. This is test-driven: define what
"correct" looks like first, then verify the implementation matches.

**State write**: write `stage-outputs/generate-evals.json` with
`data.evals_created[]` and `data.skipped_reason` (or `null`). Status is
`pass` even when evals are skipped (no testable surface) — record the
reason in `summary` and `data.skipped_reason`.

---

## Shared fix loop + pause shape

Stages 5, 5.5, 5.6 (and 5.7's own separate budget) all fix the same way, so the loop and its
pause are specified once, here.

**The loop.** On a gate failure: parse the structured results; for each failure extract test
name, expected-vs-actual, file path, function; dispatch **one fix agent** — **Sonnet by default**
(Opus only on `--model opus`), per the **Model cap** section — told to fix *only* those failures
with no refactor; re-run the gate. Repeat to a maximum of **3 iterations, shared across Stages
5/5.5/5.6** (Stage 5.7 has its own separate budget — see there for why sharing it is wrong).

**Stage 4 no longer exists.** It ran `eval.runner` and then Stage 5 ran the same command again as
its eval-regression layer, so its gate was a strict prefix of Stage 5's. Sharing this budget, its
pause could halt a run on **self-authored** evals before the project's real suite was ever
consulted — a weak oracle pre-empting the strong one. Stage 3 still authors the tests; Stage 5
runs them. See `plans/brainstorm-post-merge-cleanup.md` (D2).

**The pause.** On budget exhaustion, emit this block, inferring the class from *the failing
stage's own* sidecar (`validate.json`, `review.json`):

```markdown
## SDLC Pipeline — PAUSED

{stage} failures persist after {N} fix attempts.
Remaining failures:
{failures_summary}

### Diagnosis

**Fastest path: run `/status`** — it reads this sidecar, classifies the failure,
drafts the fix for a code defect, and hands back the `--resume` re-entry. Or triage inline:
- **Class** (inferred from the failing stage's sidecar `data.remaining_failures[]`): one of
  **flaky** (a test flips pass/fail across loops) · **code-defect** (a consistent assertion
  failure) · **plan-wrong** (the failure contradicts a plan step) · **config-missing** (a
  command/env/dep the runner needs).
- **Recommended next command** (matches the class — `--resume` reuses the green stages, so
  prefer it over a fresh re-run):
  - flaky → re-run just the gate to confirm: `/test-check` (or `/eval-harness`); if green, `/sdlc {plan_file} --resume`.
  - code-defect → `/task fix: {one-line failure}` (bounded TDD), then `/sdlc {plan_file} --resume` (code changed, plan didn't).
  - plan-wrong → `/brainstorm` the failing step to revise `{plan_file}`, then re-run `/sdlc {plan_file}` **fresh** (NOT `--resume` — editing the plan changes its hash, which resume rejects by design).
  - config-missing → set the missing command/env in `.claude/project.json`, then `/sdlc {plan_file} --resume`.

Fix manually (per the diagnosis above), then `/sdlc {plan_file} --resume` (or a
fresh `/sdlc {plan_file}` if you edited the plan) — resume reuses the green stages.
```

Set `run.json.status = "paused"` alongside the failing stage's sidecar `status: "paused"`.

---


## Stage 5: Validate

One stage, one gate, one sidecar. It answers the two questions that matter after implement:
**does it run, and is it what the plan asked for?**

This replaces the former Stages 5, 5.5 and 5.6. They asked the same question three ways — "do
the tests pass", "does the code fulfill the plan" (four checklist agents), "does the flow match
the plan" (a narrative trace) — each with its own dispatch, sidecar, gate and pause, and each
paying its own round of orchestrator chatter. A current model does not need the plan-vs-diff
check partitioned into api/ui/data/cross-module lanes to do it well.

### 1. Run the suite

Run the `/test-check` procedure, driven by the diff's surfaces (see
`templates/changed-files-gate.md`), with one substitution: report only **new** failures as
failures and note pre-existing ones separately.

- Log audit (if `logs.command` configured)
- Frontend unit tests (if `test.frontend` configured **and** the frontend surface was touched)
- Backend unit tests (if `test.unit` configured **and** the backend surface was touched)
- **E2E / visual check** — dispatch the `e2e-test-runner` agent (by type:
  `brainstorm-toolkit:e2e-test-runner`, or bare `e2e-test-runner` when vendored) if `test.e2e`
  is configured **and** the frontend surface was touched. It runs its own bounded fix loop with
  a flaky-test guard; its iterations count toward the shared budget. If the frontend surface was
  touched and no `test.e2e` is configured, raise a **soft-stop candidate** ("frontend changed
  but no visual check ran") — never pass silently.
- Eval regression (if `eval.runner` configured) — this is the only place evals run.

### 2. Check the delivery against the plan

**Skip when there is no plan target** (an ad-hoc `/sdlc-lite` description) — there is nothing
to check against, and say so rather than passing silently.

Dispatch **one agent** — Sonnet by default, per the **Model cap** section — with the plan and
the diff, and this brief:

> Verify the delivered change against the plan on two axes, and report them separately.
> **(a) Requirements:** walk every acceptance criterion and implementation step in the plan and
> mark it met / partially met / missing, with a `file:line` for each judgement. Feature
> completeness and behavioural correctness — not code style, which the tests and the review
> stage cover.
> **(b) Flow:** trace each flow the plan claims through the actual source, in order, and flag
> `MISMATCH` (code does something different), `UNCLEAR` (can't follow it), or `MISSING` (the
> step isn't there). This catches the case where every individual criterion passes but the
> end-to-end path silently deviates — wrong ordering, a skipped step, a different module doing
> the work.
> Return `{requirements: [...], flow: [...], green: bool}`. `green` is false if any requirement
> is missing or any flow step is `MISMATCH`/`MISSING`.

Give it the test results from step 1 as corroborating evidence. Without any test evidence
(neither `eval.runner` nor `test.unit` produced results) the flow axis degrades to mostly-grep —
still run it, but say in the report that it was unwitnessed.

For a deeper interactive trace, `/flowsim` remains available as a standalone skill; this stage
is its inline, bounded form.

### 3. Gate

Green iff no new test failures **and** `green` from step 2. On failure, route into the
**Shared fix loop + pause shape** above (3 iterations, shared with Stage 5.7's separate budget
excluded). A `MISMATCH` where the *code* is right and the *plan* is stale is a `plan-wrong`
class — pause and say so; do not "fix" code to match a stale plan.

**Writes** `stage-outputs/validate.json` with `data.layers{logs,frontend,backend,e2e,eval}`,
`data.new_failures[]`, `data.preexisting_failures[]`, `data.requirements[]`, `data.flow[]`.
The former `plan-validate.json` and `flowsim-<slug>.json` sidecars are gone; `/status` and
`/status` read `validate.json` for all of it.


## Stage 5.7 — Adversarial review

**Opt-in, permanently OFF by default.** This stage activates only on an explicit
`--review-model <name>` flag or an explicit `pipeline.review_fix.enabled: true` in
`.claude/project.json`; `--no-review` always wins OFF. An absent or `enabled: false`
`pipeline.review_fix` block means OFF — there is no default-on flip, now or later. When
activated, two auto-off gates still apply: the diff is docs-only/touches no code surface (self-skip
— **except in skill-repo mode, which never self-skips this gate**, since `.md` skill files *are*
the code surface there and would otherwise silently disable the stage in the repo that dogfoods it).

Runs after Stage 5, before Stage 6, once enabled and not auto-off'd. Fans out
**one reviewer pass per configured lens** (parallel sub-agents on Claude; sequential inline passes
on Copilot/Codex), each at the reviewer model resolved above.

**Which lenses run — `agents.code_review_lenses`.** Read the array from `.claude/project.json`;
when the key is absent, use all four defaults below. **Set fewer to cut the stage's cost roughly
linearly** — the fan-out is one reviewer call per lens at the reviewer model (Opus by default), so
`["correctness", "plan-alignment"]` is about half the cost of the full set, and `["correctness"]`
about a quarter. Pick by what the change actually risks: `correctness` is the highest-yield single
lens; add `security` for anything touching auth, endpoints, or user input; add `plan-alignment`
when the plan has acceptance criteria you care about; `config-env-docs` matters most when the diff
touches env vars, compose, or docs. An unrecognized lens name is ignored with one warning (the
config-schema enum is deliberately open so a repo can add its own). Print the resolved list —
`review lenses: <a, b, …> (N of 4 defaults)` — before dispatching, so a reduced fan-out is never
silent. The circuit breaker below may drop a lens from this resolved list at dispatch time.

**How many run — `agents.code_review_max_lenses`** (default `4`, so it is inert until set).
Applied **after** the circuit-breaker drop, truncating the resolved list **in order** — so
`1` keeps `correctness`. Use it to cut cost without having to name lenses, and without
re-editing the list if the defaults change. A non-integer or non-positive value falls through
to `4`; it must never resolve to `0`, which would silently disable the stage rather than fail it.

**The cap interaction — say it out loud when it applies.** Each lens is one call at the
*reviewer* model, plus one verify pass and one fix-planner at the same model. `models.cap` does
**not** govern this axis, deliberately. The interaction is easy to misread: `cap: sonnet` puts
the implementer on sonnet, which *satisfies* the independence check below, so the reviewer stays
at full `opus` and no bump/degrade warning ever fires. When a cap is set and the reviewer
outranks it, emit:

```
review: reviewer runs <model> on <n> lens(es) + verify + fix-planner. models.cap (<cap>) does
        NOT govern this axis — lower it with models.code_review, or cut the fan-out with
        agents.code_review_max_lenses. See templates/models.md.
```

Never "fix" this by routing the reviewer model through `capModel()` — it silently no-ops.

| Lens | What it looks for |
|---|---|
| `correctness` | Logic bugs, wrong SQL, races, param types, edge cases, side-effects. Prompt from `templates/review-correctness-checklist.md`. |
| `plan-alignment` | Every acceptance criterion in the plan actually met; no contract drift between plan and diff. |
| `config-env-docs` | Env-var names match across code/`.env.example`/compose; docs not stale; no new secrets. In skill-repo mode this lens repoints to `templates/stage-5-skill-repo.md`'s frontmatter/marketplace/template-reference checks instead — there's no `.env`/compose surface in a skill repo. |
| `security` | Injection (SQL/shell/template), missing authn/authz on new endpoints (incl. IDOR), secrets in code/logs, unsafe deserialization, SSRF/path-traversal, dependency/supply-chain risk, crypto misuse, sensitive-data exposure, XSS. Prompt from `templates/review-security-checklist.md`. Rides the reviewer-model axis like every lens — never `models.cap`. |

Each lens returns structured findings (`REVIEW_FINDING_SCHEMA`, defined in
`sdlc-pipeline.workflow.js`; `templates/state-schema.md` documents the resulting `review.json`
sidecar shape, not the schema itself): `{severity, file, line, defect, failure_scenario, fix}`.
`auto_fixable` is set later by the fix-planner (Stage 5.8) and merged in at that point — the lens
itself never returns or claims it.

**Verify pass (adversarial, evidence-required, default-refute):** one more call, same reviewer
model, that must attach a fresh falsifiable artifact to each finding it confirms — a re-read
file:line quote, a grep result, or one call-graph hop. A finding it can't ground this way is
refuted, not "probably true."

**Optional second pass** (`agents.code_review_passes: 2`, default `1`): one additional
completeness-critic call at a cheaper `models.code_review_second_pass` (default `sonnet`), given pass 1's
findings and told to find what pass 1 missed — never to re-judge or restate them. Findings are
unioned and fingerprint-deduped into pass 1's set, then the single verify pass runs once over the
combined set. This is a recall mechanism, never a vote.

**False-positive circuit breaker (Phase 4):** a per-lens rolling confirmed/raw ratio, tracked
across the last 20 runs in `.claude/pipeline/_review-stats.json`. A lens under 40% confirmed-rate
is auto-demoted from the default fan-out (logged in `review.json.data.demoted_lenses`); re-promoted
after 5 consecutive runs at ≥60%.

**Cost bound (documented follow-up, not yet enforced):** before dispatch, sum `added + removed`
from `stage-outputs/implement.json`'s `data.files_changed[]` (or, on a decomposed run, the union of
`stage-outputs/implement-<lane>.json` sidecars — no new git call). Defaults: `review.max_diff_lines`
= 1500, `review.max_files` = 25 (`pipeline.review_fix.*`). Under both: review the full diff. Over
either: partition files across the Stage 2 decompose lanes (if decomposed) or by the changed-files
gate surfaces; each lens reviews one partition, findings merge before verify, and the run records
`data.diff_lines_reviewed`, `data.partitioned`, `data.partition_count`. **This partition logic is
not yet implemented in `sdlc-pipeline.workflow.js`** — it is carried as an explicit TODO, not
silently dropped; until it lands, treat the ceilings as advisory and don't expect those three
sidecar fields to appear in `review.json`.

**Writes** `stage-outputs/review.json`. `review` is appended to `run.json.stages_completed`
whenever this stage actually ran (even with zero findings). A self-skip (never opted in, opted out
via `--no-review`/`enabled: false`, or the docs-only/no-surface auto-off gate in a
**non**-skill-repo run) is recorded in `run.json.stages_skipped` instead.

## Stage 5.8 — Fix loop

Only runs when Stage 5.7 produced **≥1 confirmed finding**. A fix-planner (reviewer model) drafts
a structured fix spec per confirmed finding, applying the `auto_fixable` rubric below.

**`auto_fixable` rubric (default-deny):** a finding is `auto_fixable: true` only if it corrects an
existing explicit contract (plan acceptance criterion, docstring/type signature, schema, test
assertion — not a reviewer opinion), does **not** change a user-observable default (config default,
UI copy, threshold constant, API response shape), names a concrete reproducible input in
`failure_scenario` (not a judgment call), and the independence check below didn't mark the run
`"degraded"`. Failing any of the first two gets `auto_fixable: false` with a `reason` field —
design decisions are never auto-fixed by construction, since the fix agent's prompt is built
exclusively from `auto_fixable:true` findings.

Per `pipeline.review_fix.mode`:
- **`interactive`** (default): present each fix spec for approve/edit/skip. Approved specs route
  through the same `runGatedFix()` pattern Stage 5 uses, but as a **new gate function** — Stage 5
  is hard-wired to the eval runner. Loop until clean or `agents.code_review_max_fix_loops`.
  `interactive` means auto-apply confirmed `auto_fixable:true` findings (bounded by budget), then
  always pause-and-return before Stage 6 with every remaining finding surfaced. True per-finding
  approve/edit/skip is prose-path-only (Claude session, Copilot, Codex can literally ask).
- **`auto`**: intended to auto-approve after `auto_approve_after` consecutive approvals (default 2),
  or when a finding's verify-confidence ≥ `confidence_threshold` (default 0.85). **This throttle is
  a documented follow-up, not yet enforced** in `sdlc-pipeline.workflow.js` — the fix-planner sets
  `auto_fixable` per the rubric, but nothing in the workflow today gates *how many* auto-fixable
  findings get auto-approved per run against these two knobs; treat them as advisory until that gap
  closes. Design-decision findings (`auto_fixable: false`) are never auto-approved in any mode —
  that branch is enforced today, independent of the throttle above.
- **`off`**: emit findings to `review.json` only; Stage 5.8 does not run.

**Independence enforcement:** the reviewer model must differ in effective tier from the
implementer's effective tier (`capModel('opus', MODEL_CAP)`); if they collide, the reviewer bumps
one tier up, or — if already at the ceiling — the run is marked `data.independence = "degraded"`
in `review.json` and every finding that run is surfaced only, never auto-fixed.

**Oscillation guard (fingerprint-based):** each confirmed finding gets a stable fingerprint —
`file + ":" + lens + ":" + floor(line / 10)`. Persist `fixed_fingerprints[]` per loop iteration.
Before approving a finding in loop `n+1`, check it against the union of all prior loops'
`fixed_fingerprints` — a match means oscillation (a later fix reintroduced an earlier one), not a
fresh bug: don't spawn another fix attempt, pause with `run.json.status = "paused"` and report the
original fix + regression side by side (same shape as Stage 5's persistent-mismatch pause).

**Writes a single cumulative** `stage-outputs/review-fix.json` (not per-iteration files), with a
`loops[]` array carrying one entry per iteration. `review-fix` is recorded once in
`run.json.stages_completed` regardless of loop count.

**Blocking posture:** a surviving HIGH-severity confirmed finding (auto-fixable and unresolved
after budget exhaustion, or a HIGH-severity design decision) **blocks** — Stage 6 does not create
a PR; `run.json.status = "paused"`, same shape as an eval max-loops pause.

**Post-fix validation:** if any fix was actually applied this run, re-run the Stage 5 `validate`
gate exactly once before Stage 6 (a single confirmation pass, not a fresh budget). A regression
there pauses the run — an objective break, not an adversarial opinion, so this always stops rather
than proceeding.

**Fix-loop budget:** its own `agents.code_review_max_fix_loops` (default `3`, `pipeline.review_fix.*`) —
**separate** from the shared 3-iteration budget pooled across Stages 4/5/5.5/5.6. Review findings
are a categorically different surface (defects a green suite structurally cannot catch, discovered
after all four of those gates already passed), so they get their own dial rather than racing a
shared counter.

---

## Stage 6: Create PR

Create a pull request for human review.

1. **Create branch**: `sdlc/{feature-slug}`
   ```bash
   git checkout -b sdlc/{feature-slug}
   ```

2. **Secret scan** the files about to be staged. Skip only if `pipeline.skip_secret_scan: true`
   in `.claude/project.json` (e.g., a security research repo where false positives dominate).

   Prefer `gitleaks` if available:
   ```bash
   if command -v gitleaks >/dev/null 2>&1; then
     gitleaks detect --no-git --source . --report-format json --report-path /tmp/gitleaks-{feature-slug}.json --exit-code 0 -- {specific files}
   fi
   ```

   If `gitleaks` is not installed, run a fallback regex sweep on the same file list for these
   high-signal patterns: `AKIA[0-9A-Z]{16}` (AWS access key), `aws_secret_access_key\s*=`,
   `-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----`, `xox[baprs]-[0-9a-zA-Z]{10,}` (Slack),
   `sk-[a-zA-Z0-9]{20,}` (OpenAI/Anthropic-style), `ghp_[a-zA-Z0-9]{36}` (GitHub PAT),
   `gh[osu]_[a-zA-Z0-9]{36}` (GitHub OAuth/server/user tokens),
   `(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*['\"][^'\"]{12,}['\"]`.

   **Policy — warn-only, never blocks commit or push**:
   - Any finding (HIGH, MEDIUM, LOW, or regex-fallback match) → record file
     and line, surface in the PR body, and **proceed** with stage + commit.
     This pipeline does not refuse to commit on a secret-scan finding alone.
   - HIGH findings get a `⚠ HIGH:` prefix and a one-line note that GitHub
     Push Protection (on public remotes) may still reject the push even
     though this skill did not. The user can scrub-and-recommit or push to a
     private remote (e.g., Tailscale-backed internal git) at their discretion.
   - If the regex fallback fires, treat all matches as HIGH for reporting purposes
     (no severity distinction in the fallback) — same warn-only behavior.

   Record the scan tool used and finding count in the PR body so reviewers know a scan ran.

   **State write**: write `stage-outputs/secret-scan.json` with `data.tool`
   (`gitleaks` or `regex-fallback`), `data.files_scanned[]`,
   `data.high_findings`, `data.medium_findings`. Status is always `pass` —
   the scan is informational, not gating.

3. **Stage and commit** all changes:
   ```bash
   git add {specific files from the implementation}
   git commit -m "feat: {feature description from plan title}

   Implemented via /sdlc pipeline from {plan_file}.

   Changes:
   {git diff --stat summary}

   Eval results: {passed}/{total} tests passed
   Test-check: {pass/fail summary}

   Co-Authored-By: Claude <noreply@anthropic.com>"
   ```

4. **Push and create PR**:
   ```bash
   git push -u origin sdlc/{feature-slug}

   gh pr create --title "feat: {short description}" --body "$(cat <<'EOF'
   ## Summary
   {1-3 bullet points from plan}

   ## Implementation
   - Plan: `{plan_file}`
   - Pipeline: /sdlc (autonomous)
   - Eval results: {passed}/{total} passed
   - Fix loops needed: {N}

   ## Test Results
   {test-check summary}

   ## Files Changed
   {git diff --stat}

   ## Eval Coverage
   {list of eval test files created}

   ---
   Generated by `/sdlc` pipeline

   Co-Authored-By: Claude <noreply@anthropic.com>
   EOF
   )"
   ```

5. **Report** the PR URL to the user

6. **Trigger code review**: invoke the built-in `/review` slash command on the
   just-created branch so the human gets a structured pass over the diff before
   they read it. `/review` writes its findings to the chat session, not to the
   PR — that's intentional, since the toolkit's default audience is the user
   driving the pipeline. If team-visible review is wanted, post the summary as
   a single PR-level comment via `mcp__github__add_issue_comment` (no thread
   tracking needed). Skip this step entirely if `pipeline.skip_review: true`
   in `.claude/project.json`.

7. **Capture at loop-exit (knowledge sink)**: run the shared protocol in
   `skills/gotcha/SKILL.md`. Auto-draft a gotcha **only** on an objective
   trigger — a fix-loop that **failed-then-recovered** (eval/test/flowsim), or
   the user voicing surprise — route it through gotcha's dedup, and one-tap
   confirm. The **durable project file is the sink, not model memory**. A clean
   run stays silent (no vibe-gating "was anything non-obvious?"). `/sdlc` commits
   the capture with the run; it does not use the `.next-action` seam.

**State write**: write `stage-outputs/pr-create.json` with `data.branch`,
`data.pr_url`, `data.pr_number`, `data.commit_sha`. On success, set
`run.json.status = "complete"`. (Stage 7 is a pure-reporting stage and writes
no sidecar — `run.json` is the terminal record.)

**Close TASKS.md rows.** Mark `[x]` and move to `Done` any `Active / Pending`
row that referenced this plan (by slug/path — including rows `/brainstorm`
appended for it) or was resolved as an implementation step. A plan with no
matching rows closes none — report that, don't force one.

**Leave re-entry rows.** Closing the delivered rows is not the end of the loop —
append the follow-up work so the queue knows about it (the back-edge the pipeline
otherwise lacks: a finished run seeds its own next step instead of dead-ending):
- Always (PR path): `- [ ] (P2) verify PR #<n> of <slug> merged & deployed — /repo-health`
- When the changed-files gate flagged the **deploy-delta** surface (a
  manifest/lockfile/Dockerfile changed): `- [ ] (P1) rebuild <env> for <slug> (dependency change — rebuild, not restart) — plans/<slug>.md`
- When a soft-stop was overridden: the debt row per **Soft-stop** below.

**Always close the run.** Whatever exit path you take — success, a pause at
Stage 5/5.5/5.6, or bailing because you committed something by hand — set
`run.json.status` to a terminal value (`complete` / `paused` / `failed`)
before you stop. An envelope left `in_progress` after the work moved on is the
"stale pipeline" smell `/repo-health` Check 7 and `/status` will flag; don't
manufacture one.

**Record the durable next action (L8).** At that same close point, also set
`run.json.next_action = {"cmd": <the proposed next command>, "confirm": <true iff it
writes git history>}` whenever the run proposes a follow-up — on **pause**, the
`/status` or `/sdlc <plan> --resume` from the Diagnosis; on **complete**, the
primary re-entry row's command (e.g. `/repo-health`). This mirrors
the `.next-action` sentinel into the envelope so `/status` recovers the handoff *after* the
fire-once sentinel was consumed (best-effort, additive — see `templates/state-schema.md`).
Omit it when there's no follow-up.

This applies equally to **retro / validation-only runs** — where Stage 2
(implement) is intentionally skipped because the implementation already landed
in a prior commit (a run started with notes like "retro-running validation
stages"). Such a run must still **advance `run.json.stage` and append to
`stages_completed` as each validation sidecar is written**, add `implement` to
`run.json.stages_skipped`, and finish on a terminal `status`. The failure mode
to avoid: a retro run initialized at `stage: "parse"` whose validation sidecars
(`sanity-check`, `generate-evals`, `validate`,
`flowsim`) all exist on disk while `run.json` still reads
`status: "in_progress"` with `stages_completed: []` — sidecars present but the
run never closed. That orphan is the single most common stale-pipeline false
alarm; closing the run is the last action of *every* exit path, retro included.

**IMPORTANT: Do NOT switch back to the main branch after creating the PR.**
Stay on the feature branch so the user can test the feature before merging.
Only switch branches when the user explicitly says to. (Main branch name is
read from `main_branch` in `.claude/project.json`, default `main`.)

---

## Stage 7: Report to User

Report completion to the user:

```markdown
## Ready for Human Testing

**PR**: {url}
**Branch**: sdlc/{feature-slug} (stay on this branch)
**Test results**: {summary from Stage 5}

{If the deploy-delta surface was touched (see changed-files gate), lead with:}
⚙ **Rebuild required (not restart)** — this change touched {manifest/lockfile/
Dockerfile}, so the deployed/test environment must be rebuilt, not just
restarted, to pick it up. {If new test files were added and the test runner is
containerized with a baked test dir, note they need copying/rebuild first.}

Please test:
- [ ] {key interaction 1}
- [ ] {key interaction 2}
```

---

## Safety Rules

- **Never push to the main branch directly** — always create a branch and PR
- **Never merge the PR** — human reviews and merges
- **Never switch back to main after PR creation** — stay on the feature branch so the user can test
- **Stop on ambiguity** — if the plan has unclear steps, pause and ask
- **Stop on repeated failures** — if fix loop can't resolve after max iterations, report to user
- **Don't fix pre-existing failures** — only fix what this pipeline introduced
- **Git hygiene** — clean commits with descriptive messages, specific file staging (no `git add .`)
- **Autonomy overrides interactive output styles** — `/sdlc` is an autonomous plan→PR pipeline. If an interactive output style (e.g. a "learning"/contribution-seeking mode) is active, the explicit `/sdlc` invocation wins: run autonomously, don't pause to solicit user-authored code mid-pipeline.

## Soft-stop tier (earn the interruption)

Most gates here are **warn-only** (the secret scan is the model: surface, never
block — false positives shouldn't train users to disable a gate). But a tiny
allowlist of *structural* gaps earns one **soft-stop** — a single
"proceed anyway?" confirmation, never a hard refusal:

- Sanity-check (Stage 1.5) was skipped on a multi-file plan.
- A prior pipeline run on this branch is still `in_progress` at commit time
  (continuity detection fired and was ignored).
- Frontend files changed but no visual/e2e check ran (see the changed-files
  gate in Stage 5).

Soft-stop = ask once, proceed on confirmation, and log a one-line TASKS.md
debt row if overridden. Keep the allowlist short; spending an interruption on
a regex-level false positive is how gates get disabled.

**Non-interactive runs (background job / CI / `--print`):** a soft-stop must
**never block waiting for an answer that can't come** — that's a deadlock, not
a gate. When there's no interactive channel (you're a background agent, a CI
step, or a headless `claude --print` invocation), **proceed-and-document**
instead of asking: take the safe path, write the soft-stop reason into the PR
body, and add a TASKS.md debt row so the skipped check is visible and owned.
Detect non-interactivity from the run context (no human in the loop); when in
doubt in a background/CI context, proceed-and-document rather than stall.

## When This Skill Works Best

- Bounded, well-specified plans with clear file paths and acceptance criteria
- Script creation, API endpoints, CRUD operations, refactors
- Any plan file with concrete steps and verifiable outcomes

## When to Skip or Use Cautiously

- UI/UX design work — human judgment needed for "feel"
- LLM prompt tuning — evals can't capture personality/tone reliably
- Cross-module features with ambiguous tradeoffs — brainstorm more first

---

## Skill-repo mode (auto-detected)

Use when the repo being changed is itself a markdown-skill plugin (like
brainstorm-toolkit). The standard pipeline is shaped for "code-with-tests"; a
skill repo has no test surface, so eval-driven stages are inapplicable.

**Detection**: at Stage 1, if `.claude-plugin/marketplace.json` exists at the
repo root, this mode activates automatically. No flag required.

### Stage substitutions

| Standard stage | Skill-repo behavior |
|---|---|
| Stage 1 — Parse plan | unchanged |
| Stage 1.5 — Sanity check | unchanged (the configured focus agents generalize fine; defaults are the 3 Haiku ones) |
| Stage 2 — Implement | unchanged (gated as standard; a skill repo's single docs surface normally keeps it single-agent) |
| Stage 3 — Generate evals | **skip** (no test surface) |
| Stage 5 — Full validation | **substitute** with the procedure in `templates/stage-5-skill-repo.md` |
| Stage 5.7 — Adversarial review | **adapt** — still runs; correctness + plan-alignment lenses apply equally to prose/JS, and the `security` lens applies its skill-repo shell-injection check (item 10 — quoting/eval in skill prose + hook scripts). The `config-env-docs` lens repoints to the skill-authoring checks in `templates/stage-5-skill-repo.md` (frontmatter/metadata, marketplace registration, template-reference resolution) since there is no `.env`/compose surface in a skill repo. |
| Stage 5.8 — Fix loop | unchanged (same approve/auto/off machinery) |
| Stage 6 — Create PR | unchanged |
| Stage 6 secret scan | unchanged (still scans staged files) |

### What runs in substituted Stage 5

Read `templates/stage-5-skill-repo.md` and execute its checks (HARD: validator,
marketplace registration, template-reference resolution, setup.sh dry install;
SOFT: line-count ceiling, README skills-table drift, copilot overlay parity).
Embed the result table in the PR body.

This mode keeps `/sdlc`'s discipline (sanity-check → implement → validate → PR)
while swapping in the right validation surface for the artifact type.

### State envelope in skill-repo mode (auto-detected)

Skipped stages (`generate-evals`, `validate`)
write **no sidecar**; their names are appended to `run.json.stages_skipped`
instead. The substituted Stage 5 writes `stage-outputs/validate.json` with
`data.mode = "skill-repo"` and the structural-check results — see
`templates/state-schema.md` for the exact shape.
