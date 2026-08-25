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
/brainstorm → plan → /sdlc → sanity-check → implement → eval → fix → validate → PR → human review
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
- When skill-repo mode is auto-detected, the skipped stage (`generate-evals`)
  writes **no sidecar**; add its name to `run.json.stages_skipped` instead.
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

**Read `skills/sdlc/templates/resumption.md` now** when `--resume` is passed.

`/sdlc <plan> --resume` picks up a paused/failed prior run instead of restarting: read `run.json`,
reject on a `plan_hash` mismatch, skip stages whose sidecar shows `status: "pass"`, resume at the
first non-passing one. The template carries the full rule set and the rejection messages.

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

**Read `skills/sdlc/templates/output-verbosity.md` now**, before any stage prints.

**Default `quiet`** — one line per stage (`<stage> · <verdict> · model: <tier> (cap: <cap|none>)`),
one summary table at Stage 7, no intermediate narration or echoed sub-agent output. Always print
regardless of verbosity: the per-dispatch `model:` line, gate verdicts, PAUSE blocks, the `Next:`
seam line, and warnings. `pipeline.output.verbosity: "normal"` restores narration.

## Stage 1.5: Plan Sanity Check

Before spending implementation tokens, verify the plan is actually correct.

**Read `skills/sdlc/templates/stage-1.5-sanity-check.md` now** — it carries the orchestration
(focus selection via `agents.sanity_focuses`, the `models.sanity` tier, the parallel dispatch,
processing results and the sidecar) followed by the per-focus agent prompts.

This is cheap insurance — it catches wrong file paths, missing steps and known gotchas before
they become bugs. Critical issues (plan references nonexistent files, the approach is
misguided) **STOP** the run for human revision; lesser issues auto-patch the plan and proceed.
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

**Read `skills/sdlc/templates/stage-2-gate.md` now.** It computes `surfaces_touched`,
`task_count` and disjointness from `stage-outputs/parse.json`, and routes: **decompose iff**
`surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` (default `6`) AND the
per-surface file sets are disjoint — otherwise the single-agent fallback below. Record the
decision and its inputs; never a silent choice.

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

**Read `skills/sdlc/templates/stage-3-evals.md` now**, then run it.

Create test cases that verify the plan's INTENT, not just "does it compile." The template covers
the four surface shapes (new pure functions, JSON-emitting scripts, functions inside an
application package, and no-testable-surface), the `data.coverage_route` record, and the sidecar.

**Skip silently when no `eval.runner` is configured** — record `data.skipped_reason`.

---

## Shared fix loop + pause shape

**Read `skills/sdlc/templates/fix-loop.md` now**, at the first gate that fails.

Stages 5 and 5.7/5.8 all fix the same way, so the loop and its pause block are specified once,
there: dispatch one fix agent per failure set (Sonnet by default), re-run the gate, 3 iterations
max, then emit the PAUSE block with its class-based diagnosis and set `run.json.status = "paused"`.

**Stage 4 no longer exists.** It ran `eval.runner` and then Stage 5 ran the same command again as
its eval-regression layer, so its gate was a strict prefix of Stage 5's. Sharing this budget, its
pause could halt a run on **self-authored** evals before the project's real suite was ever
consulted — a weak oracle pre-empting the strong one. Stage 3 still authors the tests; Stage 5
runs them. See `plans/brainstorm-post-merge-cleanup.md` (D2).

---


## Stage 5: Validate

**Read `skills/sdlc/templates/stage-5-validate.md` now**, then run it.

One stage, one gate, one sidecar. It answers the two questions that matter after implement:
**does it run, and is it what the plan asked for?** The template carries both steps (the
`test-runner` dispatch and the plan check), the flow axis's evidence gate, and the gate rule.

This replaces the former Stages 5, 5.5 and 5.6. They asked the same question three ways — "do
the tests pass", "does the code fulfill the plan" (four checklist agents), "does the flow match
the plan" (a narrative trace) — each with its own dispatch, sidecar, gate and pause, and each
paying its own round of orchestrator chatter. A current model does not need the plan-vs-diff
check partitioned into api/ui/data/cross-module lanes to do it well.


## Stages 5.7 / 5.8 — Adversarial review + fix loop

**Read `skills/sdlc/templates/stage-5.7-review-fix.md` now — but only if the stage is enabled.**

**Opt-in, permanently OFF by default.** The stage activates only on an explicit
`--review-model <name>` flag or an explicit `pipeline.review_fix.enabled: true` in
`.claude/project.json`; `--no-review` always wins OFF. An absent or `enabled: false`
`pipeline.review_fix` block means OFF — there is no default-on flip, now or later.

Resolve that gate **before** opening the template. When the stage is OFF, do not load it: append
`review` to `run.json.stages_skipped` and go to Stage 6. The template carries the lens fan-out,
the `agents.code_review_lenses` / `code_review_max_lenses` bounds, the reviewer-model axis and its
cap caveat, the verify pass, the circuit breaker, the `auto_fixable` rubric, the fix-loop modes and
budget, the oscillation guard, and the blocking posture. Runs after Stage 5, before Stage 6.

---

## Stage 6: Create PR

Create a pull request for human review.

1. **Create branch**: `sdlc/{feature-slug}`
   ```bash
   git checkout -b sdlc/{feature-slug}
   ```

2. **Secret scan** — **read `skills/sdlc/templates/secret-scan.md` now** and run it over the
   files about to be staged. Skip only if `pipeline.skip_secret_scan: true`. Writes
   `stage-outputs/secret-scan.json`; status is always `pass` — the scan is informational.
   This pipeline does not refuse to commit on a secret-scan finding alone.
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
   trigger — a fix-loop that **failed-then-recovered** (eval/test/flow), or
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
Stage 5, or bailing because you committed something by hand — set
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
(`sanity-check`, `generate-evals`, `validate`) all exist on disk while `run.json` still reads
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
