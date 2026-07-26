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

## Execution mode — prose by default, deterministic Workflow when ultracode is on

This skill has **two** equivalent expressions of the same pipeline. **The prose
Stages 1–7 below are the default and the source of truth.** Use the Workflow
only when explicitly opted in.

**Use the deterministic Workflow IFF ALL of these hold:**
- you are on **Claude Code with the Workflow tool available**, AND
- **ultracode is explicitly enabled** — the user typed `ultracode`, the session
  has ultracode on, or the user asked for the Workflow / multi-agent
  orchestration by name, AND
- `pipeline.skip_workflow` is **not** `true` in `.claude/project.json`, AND
- **`--resume` was not passed** — resuming a paused envelope is a prose-path
  feature. The Workflow's script sandbox has no filesystem access (it can't read
  prior `stage-outputs/*.json` to know which stages already passed), so a
  `--resume` run always takes the prose Stages below. (The Workflow's own
  `resumeFromRunId` is a *same-session* script-cache resume — a different thing
  from resuming a paused pipeline across sessions.)

When all three hold, invoke:

```
Workflow({
  scriptPath: ".claude/skills/sdlc/workflows/sdlc-pipeline.workflow.js",
  args: { mode: "sdlc", plan_file: "<plan path>",
          model_cap: "<resolved cap: --model flag > project.json models.cap > null>",
          review_model: <the --review-model value, or null if the flag was not passed>,
          no_review: <true iff --no-review was passed, else false> }
})
```

The Workflow (`workflows/sdlc-pipeline.workflow.js`) encodes the control flow the
prose only describes — the Stage 2 decompose gate arithmetic, the *single*
3-iteration fix budget shared across Stages 4/5/5.5/5.6, dependency-ordered lane
dispatch, and the parallel barriers — as code, so they can't be miscounted,
silently serialized, or mis-gated. The script orchestrates; each stage's **agent**
does the work and writes the state envelope (the script sandbox has no filesystem
access). Resumable via `resumeFromRunId`.

**Otherwise — the default — follow the prose Stages 1–7 below.** That default
path covers: any Claude run where ultracode wasn't requested, Copilot and Codex
(no Workflow tool — Codex has its own plan mode, but not this JS orchestration
primitive), older Claude Code without the tool, and `skip_workflow: true`. **The
prose stages are the source of truth; the Workflow mirrors them.** If you change
a stage's contract, change the prose first, then bring the Workflow + overlays
into line (and re-run `node --check`-style validation on the script) — see
`CLAUDE.md` → "Workflow-backed skills … the three-way sync contract".

## Arguments

- `plan_file` (required): Path to the plan (e.g., `plans/my-feature.md`)
- `--resume` (optional): resume a paused/failed prior run for this plan's slug
  instead of starting fresh — skips stages whose sidecar already shows
  `status: "pass"` and picks up at the first non-passing stage, reusing the
  evidence the prior run wrote. See **Resumption** below. Forces the prose path.
- `--model <tier>` (optional): per-run fan-out cap override; see **Model cap**
  and [`templates/model-cap.md`](templates/model-cap.md). `tier` ∈
  `haiku|sonnet|opus`. **Not an alias for `--review-model`** — `--model fable`
  is an unrecognized value for this flag (per `model-cap.md`'s invalid-input
  rule: ignore, warn once, fall through to `models.cap`/default) and must
  resolve to the configured cap *before* it is ever passed as `args.model_cap`
  — never forward the raw typo'd string, since forwarding it un-caps every
  Opus dispatch in the Workflow.
- `--review-model <name>` (optional): per-run reviewer-model override; see
  **Reviewer model** and [`templates/review-model.md`](templates/review-model.md).
  `name` ∈ `fable|opus|sonnet|haiku`. Default `opus`. Passing `fable` (or
  setting `pipeline.review_fix.model: "fable"`) is a valid, explicit,
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
  `eval-fix`, `plan-validate`, `flowsim`) write **no sidecar**; add their
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

Resume is **prose-path only** — the Workflow sandbox can't read prior sidecars
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
   Continuation is a *feature-branch* concern. This is the fix for the
   "every merged feature flags on long-lived main" false positive.
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
[`templates/model-cap.md`](templates/model-cap.md): `--model <tier>` flag >
`project.json` `models.cap` > the tier named at the site. **Before each
dispatch, print `model: <tier> (cap: <cap|none>)`** and dispatch at that tier.
**The default is Sonnet-first**: with no `--model`/`models.cap` set the fan-out
resolves to Sonnet (Opus sites → Sonnet, Haiku stays Haiku); `--model opus` opts
a run up to Opus. Emit the session-model nudge once when a cap is active. On the Workflow path the same
resolution is enforced by `capModel()` at the `agent()` seam.

## Stage 1.5: Plan Sanity Check

Before spending implementation tokens, verify the plan is actually
correct. Launch 3 Haiku agents **in parallel** (single message) to check
different dimensions. This is cheap insurance — catches wrong file paths,
missing steps, and known gotchas before they become bugs.

Read the prompts from `templates/stage-1.5-sanity-check.md` (sections: `paths`,
`completeness`, `gotchas`). Substitute `{plan_file}` and `{feature_name}`, then
dispatch all three Haiku agents in a single message — one Agent call per section.

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
   `.claude/project.json` `pipeline.decompose_min_tasks`.
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
go to the Stage 4 fix loop). Write `stage-outputs/converge.json` with
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
   Stage 5.6 (flowsim) knows unit results are the corroborating evidence.

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

## Stage 4: Eval + Fix Loop

Run the evals and auto-fix failures.

```bash
<eval.runner> --feature {feature_slug} --output json
```

(`eval.runner` from `.claude/project.json`. If not configured, skip Stage 3-4 with
a note: "No `eval.runner` configured — skipping eval generation and fix loop.")

### If all green:
Proceed to Stage 5.

### If failures:
1. Parse the structured JSON results
2. For each failure, extract: test name, expected vs actual, file path, function
3. Spawn a fix agent — **Sonnet by default** (Opus only on `--model opus`
   opt-up), per the **Model cap** section — using
   the prompt at `templates/stage-4-fix-eval.md`. Substitute `{feature_name}`,
   `{results_json}`, and `{file_paths}` before dispatch.
4. After fix agent completes, re-run evals
5. Repeat up to 3 iterations
6. If still failing after 3 iterations:

```markdown
## SDLC Pipeline — PAUSED

Eval failures persist after {N} fix attempts.
Remaining failures:
{failures_summary}

### Diagnosis

**Fastest path: run `/triage <slug>`** — it reads this sidecar, classifies the failure,
drafts the fix for a code defect, and hands back the `--resume` re-entry. Or triage inline:
- **Class** (inferred from this stage's sidecar, here `stage-outputs/eval-fix.json`
  `data.remaining_failures[]`): one of **flaky** (a test flips pass/fail across loops) ·
  **code-defect** (a consistent assertion failure) · **plan-wrong** (the failure
  contradicts a plan step) · **config-missing** (a command/env/dep the runner needs).
- **Recommended next command** (matches the class — all work today; `--resume` reuses the
  green stages, so prefer it over a fresh re-run):
  - flaky → re-run just the gate to confirm: `/eval-harness` (or `/test-check`); if green, `/sdlc {plan_file} --resume`.
  - code-defect → `/task fix: {one-line failure}` (bounded TDD), then `/sdlc {plan_file} --resume` (code changed, plan didn't — resume skips the green stages).
  - plan-wrong → `/brainstorm` the failing step to revise `{plan_file}`, then re-run `/sdlc {plan_file}` **fresh** (NOT `--resume` — editing the plan changes its hash, which resume rejects by design).
  - config-missing → set the missing command/env in `.claude/project.json`, then `/sdlc {plan_file} --resume`.

Fix manually (per the diagnosis above), then `/sdlc {plan_file} --resume` (or a
fresh `/sdlc {plan_file}` if you edited the plan) — resume reuses the green stages.
```

This **Diagnosis block is the shared pause shape** — every other pause site below
("same shape as Stage 4's pause") includes it, inferring the class from *its own*
stage sidecar (`plan-validate.json`, `flowsim-<slug>.json`, `review.json`, …).

**State write**: write `stage-outputs/eval-fix.json` with `data.fix_loops_run`,
`data.max_fix_loops` (always `3`), `data.final_pass_count`,
`data.final_fail_count`, `data.remaining_failures[]`. Status is `pass` if all
green, `paused` on max loops with persistent failures (set
`run.json.status = "paused"` too).

---

## Stage 5: Full Validation

Run the complete test suite to ensure no regressions.

**First, compute the changed-files gate** (see `templates/changed-files-gate.md`):
read `stage-outputs/implement.json` `data.files_changed[]` and mark which
surfaces (frontend / backend / data / docs) were touched. The substitutions
below are *driven by that gate*, not by the user's prompt — "frontend changed"
is a fact about the diff, so the visual/e2e check fires automatically rather
than waiting to be asked.

1. Run `/test-check` via the test-check skill procedure, BUT with one substitution:
   - Log audit (if `logs.command` configured)
   - Frontend unit tests (if `test.frontend` configured and **frontend surface touched**)
   - Backend unit tests (if `test.unit` configured and **backend surface touched**)
   - **E2E / visual check — dispatch the `e2e-test-runner` agent** (if `test.e2e`
     configured and **frontend surface touched** per the gate). The agent runs a
     fix loop for e2e failures with a flaky-test guard; its iterations count
     toward the 3-iteration eval-fix budget. If `test.e2e` is not configured but
     the frontend surface was touched, surface that as a **soft-stop candidate**
     ("frontend changed but no visual check ran" — see "Soft-stop tier"), don't
     pass silently.
   - Eval regression (if `eval.runner` configured)

2. **If NEW failures** in the non-e2e layers:
   - Go back to Stage 4 fix loop with the test-check failures
   - The fix agent receives the test output, not eval output

3. **If the e2e agent returns `failed_after_max_iterations`**:
   - Its report lists the persistent failures. Include them in the PAUSE message
     (same shape as Stage 4's max-loops pause). Do NOT proceed to Stage 5.5.

4. **If only pre-existing failures**:
   - Note them in the PR body but proceed — don't fix what was already broken

5. **If all green**: Proceed to Stage 5.5

**State write**: write `stage-outputs/validate.json` with `data.layers`
(per-layer status: logs, frontend, backend, e2e, eval), `data.new_failures[]`,
`data.preexisting_failures[]`. In skill-repo mode (auto-detected) this stage
is replaced by the skill-repo validation procedure (see "Skill-repo mode"
below); the sidecar then carries `data.mode = "skill-repo"` with the
structural-check results documented in `templates/state-schema.md`.

---

## Stage 5.5: Plan Requirements Validation

Re-read the plan file and validate that the implementation actually fulfills every
requirement. This catches "code works but feature is incomplete" — the gap between
passing tests and a working product.

**Skip this stage if no `eval.runner` is configured** (no test surface to
validate against). Skip-on-skill-repo is handled by the skill-repo mode
substitutions below.

### Decide which validators to launch

Don't fan out to all four agents unconditionally — gate each one on whether the plan
actually touches that surface area. Use the `files_changed` and `Implementation Steps`
sections of the plan to decide:

| Validator | Launch when the plan… | Skip when… |
|-----------|-----------------------|------------|
| `api` | mentions any HTTP endpoint, route, controller, or `/api/*` path; or touches files in routes/, controllers/, api/, handlers/, endpoints/ | the plan touches no server-side request handlers |
| `ui` | mentions any frontend component, page, layout, or touches `.tsx`/`.jsx`/`.vue`/`.svelte` files, or paths under components/, pages/, app/, src/ui/ | the plan is backend- or script-only |
| `data` | mentions a migration, schema change, new table/column/index, or touches files under migrations/, schema/, models/ | the plan does not change DB structure |
| `cross-module` | **always** — this is the catch-all for integration gaps and is cheap (Haiku) | never |

Record the decision in the validation report header so the user can see which checks
ran. If all surfaces were touched, all four agents run — the gating is a savings on
narrow plans (single-file fixes, SonarQube targets, docs-only changes), not a default
restriction.

### Launch validation agents in parallel

Spawn the selected agents in a **single message** (parallel launch). Each agent gets the
plan file path and a specific validation focus. Use the `ux-plan-validator` agent
definition (`.claude/agents/ux-plan-validator.md`) as reference for agent behavior.

Read the prompts from `templates/stage-5.5-validation.md` (sections: `api`, `ui`,
`data`, `cross-module`). Substitute `{plan_file}`, `{feature_name}`, and
`{feature_slug}`, then dispatch the **selected** agents in a single message.

**Validator model tier.** Built-in defaults: `api` and `ui` use Sonnet; `data` and
`cross-module` use Haiku. `.claude/project.json` `pipeline.plan_validate.model`
(`haiku|sonnet|opus`) **replaces the built-in default for all four validators** when set —
use it when you want a stronger reader judging the plan, since `cross-module` always runs
and is the catch-all for integration gaps. The resolved tier still passes through the
**model cap** (`models.cap` / `--model`, see `templates/model-cap.md`), which is a
*ceiling*: `capModel(effective_default, cap)`. Two consequences worth stating plainly —
the cap can only lower the tier, never raise it, so with the Sonnet-first default cap
`plan_validate.model: "opus"` still dispatches Sonnet unless you also pass `--model opus`;
and raising the tier costs on **every** run that reaches this stage, because
`cross-module` is unconditional. This is **not** a third model axis — it sets a default
*within* the fan-out axis and is still capped by it. Print the resolved tier with the
usual `model: <tier> (cap: <cap|none>)` line before dispatching.

### Process results

1. Collect results from all agents
2. Merge into a single validation report
3. **If all checks pass**: proceed to Stage 5.6
4. **If failures found**:
   - Feed the failure list back into the Stage 4 fix loop
   - The fix agent receives the validation report, not eval output
   - Re-run validation after fixes (counts toward the 3-iteration budget)
5. **If failures persist after 3 iterations**: report to user and stop

```markdown
## Plan Validation Report

| Focus | Checks | Passed | Failed |
|-------|--------|--------|--------|
| API   | N      | X      | Y      |
| UI    | N      | X      | Y      |
| Data  | N      | X      | Y      |
| Cross | N      | X      | Y      |

### Failures
{list of specific failures with suggested fixes}
```

**State write**: write `stage-outputs/plan-validate.json` with
`data.validators_launched[]`, `data.validators_skipped[]` (which gating
decisions skipped), `data.totals`, `data.failures[]`.

---

## Stage 5.6: Flow Simulation (plan vs. implementation)

After Stage 5.5's checklist validation passes, run **`/flowsim`** as a narrative
cross-check: trace each claimed flow through the actual source and flag MISMATCH,
UNCLEAR, or MISSING steps. This catches the class of gap where every individual
checklist item passes but the end-to-end flow silently deviates from the plan's
intent (wrong ordering, skipped step, different module doing the work).

**Skip this stage only if there is NEITHER eval results NOR `test.unit`
results to corroborate** — i.e. no test evidence of any kind. flowsim accepts
**`test.unit` results as corroborating evidence**, not just
`eval.features_dir/.../results.json`; this is what makes it meaningful for an
app-package feature that routed coverage to `test.unit` (Stage 3 above). Only
when both are absent does flowsim degrade to mostly-grep, and then it's best
run interactively via `/flowsim`. Skill-repo mode skips this stage via the
substitution table below.

### Invoke

Invoke the `/flowsim` skill with the plan file and feature slug:

```
/flowsim {plan_file} --max-hops 3
```

`/flowsim` writes two artifacts:
- A markdown report (shown to the user).
- A structured JSON at `plans/flowsim-{feature_slug}.json` that this stage consumes.

### Process results

1. **Read** `plans/flowsim-{feature_slug}.json`.
2. **Count** flows by status. Any flow with `status: "MISMATCH"` is a finding.
3. **If no mismatches**: record "flowsim: all flows aligned" in the commit trailer and proceed to Stage 6.
4. **If mismatches found**:
   - Feed the `mismatches` array into the Stage 4 fix loop.
   - The fix agent receives the structured JSON, not the markdown.
   - Re-run `/flowsim` after fixes (counts toward the 3-iteration budget).
5. **If mismatches persist after 3 iterations**:
   - Report to user with the specific file:line anchors that keep failing.
   - Do NOT proceed to PR — the plan and implementation disagree and a human should adjudicate (sometimes the plan was wrong, not the code).

### When to trust vs. question the flowsim output

- **A MISMATCH with a concrete `file:line` anchor** is high-signal: the code at that location actually differs from the plan. Fix or update the plan.
- **A MISSING marker** means flowsim couldn't find the claimed code at all. Could mean: not implemented, implemented elsewhere with a different name, or the plan was aspirational. Worth a human look.
- **An UNCLEAR** means the plan's language was too fuzzy to trace. Usually indicates a plan quality issue, not a code issue — re-run after clarifying the plan.
- **Corroborating eval evidence** (a passing or failing eval aligned with a flow step) is your highest-confidence signal; prioritize fixing those first.

**State write**: write `stage-outputs/flowsim.json` summary sidecar with
`data.report_path`, `data.json_path` (pointer to the canonical
`plans/flowsim-<slug>.json`), `data.flow_count`, `data.mismatches`,
`data.unclear`, `data.missing`. The sidecar is a *summary*, not a duplicate —
the canonical structured output remains in `plans/flowsim-<slug>.json`.

---

## Reviewer model (Stage 5.7/5.8 only)

Independent from **Model cap** above. See
[`templates/review-model.md`](templates/review-model.md): `--review-model <name>` flag >
`pipeline.review_fix.model` (project.json) > skill default `opus`. Never governed by
`models.cap` / `--model`; none of `fable`/`opus`/`sonnet`/`haiku` on this axis is a member of the
`haiku < sonnet < opus` cap rank. `fable` remains a valid, explicit opt-in (`--review-model
fable`) — usage-billed since Claude Fable 5's 2026-07-07 promotional-access sunset, which is why it
is no longer the default.

## Stage 5.7 — Adversarial review

**Opt-in, permanently OFF by default.** This stage activates only on an explicit
`--review-model <name>` flag or an explicit `pipeline.review_fix.enabled: true` in
`.claude/project.json`; `--no-review` always wins OFF. An absent or `enabled: false`
`pipeline.review_fix` block means OFF — there is no default-on flip, now or later. When
activated, two auto-off gates still apply: the diff is docs-only/touches no code surface (self-skip
— **except in skill-repo mode, which never self-skips this gate**, since `.md` skill files *are*
the code surface there and would otherwise silently disable the stage in the repo that dogfoods it).

Runs after Stage 5.6 flowsim, before Stage 6, once enabled and not auto-off'd. Fans out
**4 reviewer passes on distinct lenses** (parallel sub-agents on Claude; sequential inline passes
on Copilot/Codex), each at the reviewer model resolved above:

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

**Optional second pass** (`pipeline.review_fix.passes: 2`, default `1`): one additional
completeness-critic call at a cheaper `second_pass_model` (default `sonnet`), given pass 1's
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
  through the same `runGatedFix()` pattern Stage 4 uses, but as a **new gate function** — Stage 4
  is hard-wired to the eval runner. Loop until clean or `review.max_fix_loops`. **Workflow-tool
  limitation:** the Workflow has no mid-run human-prompt primitive, so under the Workflow
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
original fix + regression side by side (same shape as Stage 5.6's persistent-mismatch pause).

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

**Fix-loop budget:** its own `review.max_fix_loops` (default `3`, `pipeline.review_fix.*`) —
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
- Always (PR path): `- [ ] (P2) verify PR #<n> of <slug> merged & deployed — /post-deploy-verify plans/<slug>.md`
- When the changed-files gate flagged the **deploy-delta** surface (a
  manifest/lockfile/Dockerfile changed): `- [ ] (P1) rebuild <env> for <slug> (dependency change — rebuild, not restart) — plans/<slug>.md`
- When a soft-stop was overridden: the debt row per **Soft-stop** below.

**Always close the run.** Whatever exit path you take — success, a pause at
Stage 4/5.5/5.6, or bailing because you committed something by hand — set
`run.json.status` to a terminal value (`complete` / `paused` / `failed`)
before you stop. An envelope left `in_progress` after the work moved on is the
"stale pipeline" smell `/repo-health` Check 7 and `/status` will flag; don't
manufacture one.

**Record the durable next action (L8).** At that same close point, also set
`run.json.next_action = {"cmd": <the proposed next command>, "confirm": <true iff it
writes git history>}` whenever the run proposes a follow-up — on **pause**, the
`/triage <slug>` or `/sdlc <plan> --resume` from the Diagnosis; on **complete**, the
primary re-entry row's command (e.g. `/post-deploy-verify plans/<slug>.md`). This mirrors
the `.next-action` sentinel into the envelope so `/next` recovers the handoff *after* the
fire-once sentinel was consumed (best-effort, additive — see `templates/state-schema.md`).
Omit it when there's no follow-up.

This applies equally to **retro / validation-only runs** — where Stage 2
(implement) is intentionally skipped because the implementation already landed
in a prior commit (a run started with notes like "retro-running validation
stages"). Such a run must still **advance `run.json.stage` and append to
`stages_completed` as each validation sidecar is written**, add `implement` to
`run.json.stages_skipped`, and finish on a terminal `status`. The failure mode
to avoid: a retro run initialized at `stage: "parse"` whose validation sidecars
(`sanity-check`, `generate-evals`, `eval-fix`, `validate`, `plan-validate`,
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
| Stage 1.5 — Sanity check | unchanged (3 Haiku agents — they generalize fine) |
| Stage 2 — Implement | unchanged (gated as standard; a skill repo's single docs surface normally keeps it single-agent) |
| Stage 3 — Generate evals | **skip** (no test surface) |
| Stage 4 — Eval + fix loop | **skip** |
| Stage 5 — Full validation | **substitute** with the procedure in `templates/stage-5-skill-repo.md` |
| Stage 5.5 — Plan validators | **skip** (no api/ui/data surfaces) |
| Stage 5.6 — Flowsim | **skip** (skills aren't "flows") |
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

Skipped stages (`generate-evals`, `eval-fix`, `plan-validate`, `flowsim`)
write **no sidecar**; their names are appended to `run.json.stages_skipped`
instead. The substituted Stage 5 writes `stage-outputs/validate.json` with
`data.mode = "skill-repo"` and the structural-check results — see
`templates/state-schema.md` for the exact shape.
