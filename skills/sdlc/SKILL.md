---
name: sdlc
description: >
  Run the full SDLC pipeline on a plan file, task id, task range (e.g. "1-5"), or
  an ad-hoc description: sanity-check → implement → evals → fix → validate →
  flowsim, then hand off the validated changes in your working tree for you to
  commit. Never commits, branches, pushes, or opens a PR — no git writes at all.
  Use when you want full SDLC discipline on work you will review and commit
  yourself, e.g. onto an open PR's branch.
argument-hint: "plan-file | task-id | task-range | description  [--resume] [--queue N] [--no-scope-gate]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
---

# sdlc — the full SDLC pipeline, leaving the commit to you (no git writes)

> **Toolkit paths.** Every toolkit script or template path cited here resolves, first hit wins, against: a repo-local copy installed by `setup.sh`; else the plugin root (this skill's base directory two levels up, `<base>/../..`) when it holds that path; else `~/.claude/brainstorm-toolkit/` (the global shell install).

## Safety rules (read first; these must survive context compaction)

- **No git writes — ever.** No `git add`, commit, branch, push, PR or `/review`. You hand over a
  validated working tree; the user commits.
- **A delegated run never edits `TASKS.md`** under `pipeline.tasks.writer: "orchestrator"` — the
  orchestrator owns those writes and two writers race; report the rows instead (Stage 6).
- **Stop on ambiguity** — if the plan has unclear steps, pause and ask.
- **Stop on repeated failures** — if a fix loop can't resolve within its budget,
  report rather than grinding.
- **Don't fix pre-existing failures** — only fix what this run introduced.
  Stage 5's `preexisting[]` is reported, never gated on.
- **Autonomy overrides interactive output styles** — this is an autonomous
  pipeline. If an interactive output style (a "learning"/contribution-seeking
  mode) is active, the explicit invocation wins: run autonomously, don't pause
  to solicit user-authored code mid-pipeline.
- **Stage 2 delegation is mandatory** — you do not call Write or Edit during it.
- **Never load `stage-5.7-review-fix.md` unless the review stage is ON.**

## When to use

| Skill | Input | Pipeline | Terminal action |
|---|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red→green only | commit only if you ask |
| `/sdlc <plan \| task-id \| range \| desc>` | plan, task(s), or ask | **full** (sanity→implement→evals→validate→flowsim) | **validated changes left in your working tree — you commit** |

For a single small fix with no plan behind it, prefer `/task`: the full pipeline costs more than it buys there.

Stage bodies live in `skills/sdlc/templates/` (a shared template tree, not a skill);
each stage below names the one it loads.

## Prerequisites

- You are on the branch the changes should land on (typically an open PR's
  branch). `/sdlc` never switches branches and never commits.
- `.claude/project.json` optional; every key optional. The eval stage and Stage 5's
  plan check + flowsim flow trace skip silently when their config or a plan target
  is absent.
  **But** if `project.json` is absent while `project.json.example` is present,
  warn once at Stage 0 — every gated setting (`models.cap`, `pipeline.*`, test
  commands) is silently inert and the run will report `cap: none`.
  Then, if `.claude/project.json` exists, run `bash scripts/migrate-project-json.sh check`
  and print one warning line per move: `<old> is ignored — rename to <new>; run bash
  scripts/migrate-project-json.sh apply`, and per conflict a line saying both keys are set and
  `<new>` wins. Never apply from `/sdlc`; continue either way.

## Output verbosity (default: quiet)

**Read `skills/sdlc/templates/output-verbosity.md` now** — default `quiet`, one line per stage.

## Operator questions (opt-in)

When `pipeline.question_advisor.enabled` is `true`, **read `skills/sdlc/templates/operator-gate.md`
now** and run it before asking the operator anything. Otherwise never open it.

## State envelope

Writes to `.claude/pipeline/<slug>/` — the canonical envelope
(see `skills/sdlc/templates/state-schema.md`). Two additive fields:

- `run.json.pipeline = "sdlc"`.
- Stage 6 sidecar is `handoff.json`
  (`{branch, files_changed[], committed: false, suggested_commit_msg}`)

**Resumption (`--resume`).** `/sdlc <input> --resume` resumes a paused/failed
prior run for the resolved slug instead of restarting from scratch — **read
`skills/sdlc/templates/resumption.md` now** and follow it (read `run.json`; reject on a
`plan_hash` mismatch; skip stages whose sidecar shows `status: "pass"`; resume at the first
non-passing one). The only differences are the terminal stage (hand-off, not PR) and the
`handoff.json` sidecar it writes at Stage 6. Resume
keys on the **resolved slug**, so an ad-hoc-description run must be resumed with the *same
description text* (a reworded description derives a different slug → "no prior run"); task-id
/ range / plan-file inputs resolve to a stable slug and resume cleanly.

For a task **range**, `run.json.data.task_range` records the resolved ids.

---

## Stage 0 — Resolve input

**Read `skills/sdlc/templates/stage-0-resolve.md` now** (skip it only on `--resume`, which re-reads
the envelope instead) and run it. It carries the five input shapes (plan file, task id, task
range, ad-hoc description, `--queue`), slug derivation, envelope creation with the
dirty-at-start snapshot, report-rows mode, the independence pre-check, plan parsing and
`parse.json`, the **Scope gate**, the bug-row pointer, the native task mirror and continuity
detection.

Gates decided here, without opening anything further:

- **Scope gate** runs for plan-file runs only — never for task-id / range / ad-hoc / `--queue`,
  `--no-scope-gate`, or `pipeline.tasks.writer: "orchestrator"` (the template says what each of
  those records instead).
- **Skill-repo detection** (automatic, no flag): if `.claude-plugin/marketplace.json`
  exists at repo root, the repo is itself a markdown-skill plugin — switch to the
  substitutions in **Skill-repo mode** below for the rest of the run.
- **Vendored-skill guard:** if `.claude-plugin/marketplace.json` is **absent** (an
  ordinary consumer repo) but the plan's changed files target `.claude/skills/**`,
  `.github/skills/**`, or `.agents/skills/**` — i.e. it edits *installed* skill
  copies — **stop and report.** Those edits belong upstream in the canonical
  toolkit repo and then get re-installed; shipping them through a consumer's
  pipeline diverges the vendored copy from canonical.
- **Queue-mode exception:** the plan-file slug is shared by every row of a plan, so a
  queued item derives a **distinct per-item slug** (`<plan-slug>-<row-id>`, or the
  linked task-file slug) — see **Queue mode** — otherwise all its items collide on one
  `.claude/pipeline/<slug>/` envelope.

## Queue mode (`--queue`) — attended backlog loop

Only when the argument is `--queue [N]`. **Resolve that first** — on any other input, skip this
section entirely and go to Stage 1.5 without opening the template. Under
`pipeline.tasks.writer: "orchestrator"` stop with the one line `--queue needs TASKS.md writes; set
pipeline.tasks.writer to "self"` instead.

When it *is* `--queue`, **read `skills/sdlc/templates/queue-mode.md` now** and run it. It carries
the selection rule (highest-priority `Active / Pending` row, `[~]` first), the per-item envelope
and its distinct slug, the four stop conditions, the `TASKS.md` re-scan that makes it a loop
rather than a batch, the park protocol and its **mandatory** `.claude/.next-action` sentinel, and
the long-run context-hygiene note.

## Stage 1.5 — Sanity check

**Read `skills/sdlc/templates/stage-1.5-sanity-check.md` now** and run it (parallel focus
agents on Claude; sequential on the overlays). It carries the orchestration and the per-focus
prompts. This is full SDLC discipline — it is **not** gated or optional. Built-in per-focus
defaults are `paths: haiku`, `completeness: sonnet`, `gotchas: sonnet`; `models.sanity` (a
string or a per-focus map) and `agents.sanity_focuses` tune it, and because the cap only
*lowers*, `models.sanity` is the only way to raise a focus above its default.
For a task range, run it once over the combined set before the implement loop.

If the sanity check surfaces a blocker (plan references nonexistent files,
contradictory steps), stop and report rather than implementing on a bad premise.

## Stage 2 — Implement

**Delegation is mandatory. During this stage you do not call Write or Edit.** Dispatch the
implement agent(s) below and receive `git diff --numstat` back; the file bodies stay in the
agent's context, not yours — every file body you take directly is context you carry for the
rest of the run. If a change is too small to be worth an agent, it is too small for `/sdlc` —
use `/task`.

**Read `skills/sdlc/templates/stage-2-implement.md` now**, before dispatching.

Then apply the **live-code grounding** — follow `skills/sdlc/templates/convention-grounding.md`
— and the **auto-gate**: **read `skills/sdlc/templates/stage-2-gate.md` now** — it computes
`surfaces_touched` (via `skills/sdlc/templates/changed-files-gate.md`) and `task_count`, then
decides single-agent vs. decompose.

- **Single-agent (default):** dispatch one agent with `skills/sdlc/templates/stage-2-implement.md`,
  substitute `{feature_name}`, `{plan_content}` and `{slug}`; **`models.implement`** (Sonnet
  default, per `skills/sdlc/templates/models.md`) on Claude,
  inline on Copilot/Codex. **State write (orchestrator, not the agent):** the
  agent's prompt writes no state or sidecar files — when it returns `git diff --numstat`, **you**
  write `stage-outputs/implement.json` from that summary (applying the `files_changed` rule in
  `state-schema.md` `implement`), **plus `data.dispatch`
  = `{agent_id, model}` from the dispatch result** (the only proof an agent ran), append
  `implement` to `run.json.stages_completed`, and refresh `updated_at`. No decompose/converge sidecars.
- **Decompose (large multi-surface plan):** run 2a/2b/2c —
  `skills/sdlc/templates/stage-2a-decompose.md` (decomposer at `models.implement` →
  `decompose.json`), `skills/sdlc/templates/stage-2b-dispatch.md` (one subagent
  per lane, sequential by `depends_on` → `implement-<lane>.json`), then
  `skills/sdlc/templates/stage-2c-converge.md` (orchestrator reconcile prompt — it
  also writes nothing itself). **State write (orchestrator):** after 2c's reconcile
  returns, **you** write `stage-outputs/converge.json` (`files_changed` rule applied, per 2c), set
  `run.json.data.stage2_decomposed = true` and `run.json.data.lanes` (`converge.json` carries
  each lane's `data.dispatch`, per 2c), and append a single
  `implement` (never per-lane) to `run.json.stages_completed` — the canonical stage name
  either path completes under, per `skills/sdlc/templates/state-schema.md`.

For a task **range**, the gate sees the combined file/step set. After
implementation, review `git diff --stat` and confirm expected files were
touched. Stop and report on any blocker.

## Stage 3 — Generate evals

**Read `skills/sdlc/templates/stage-3-evals.md` now** and run it. **Skip silently if no `eval.runner` is
configured** — record `data.skipped_reason: "no eval.runner"`, append `generate-evals` to
`run.json.stages_skipped` and set `data.skip_reasons.generate-evals: "no eval.runner"`. Pure-docs work
degenerates cleanly into edit + commit.

## Stage 5 — Validate

**Read `skills/sdlc/templates/stage-5-validate.md` now** and run it — one stage: (1) dispatch
the **`test-runner`** agent (Haiku, structured pass/fail only — never run the suites inline;
test output is the biggest single source of context bloat) over the touched surfaces, then
(2) **one agent** given the plan + diff that reports requirements (met/partial/missing, each
with a `file:line`) and flow (`MISMATCH`/`UNCLEAR`/`MISSING`) separately. Skip axis (2) when
there is no plan target, and say so.

Route failures through the shared fix loop (**read `skills/sdlc/templates/fix-loop.md`** at the
first failure; 3-iteration budget, and the loop stops early when two consecutive rounds fail
identically). Writes one `validate.json`.

## Stage 5.7 — Adversarial review

**Opt-in, permanently OFF by default — resolve the gate before loading anything.** ON only on an
`pipeline.review_fix.enabled: true`; `--no-review` always wins OFF. When OFF, do not load the template — append `review` to `run.json.stages_skipped` (reason in
`data.skip_reasons.review`) and go to Stage 6. When ON, **read `skills/sdlc/templates/stage-5.7-review-fix.md` now** and run it: it
carries the lens fan-out and its cost knobs, the reviewer-model axis and its cap caveat, the verify
pass and the circuit breaker. Runs after Stage 5, before Stage 6; writes `stage-outputs/review.json`.

## Stage 5.8 — Fix loop

Specified in that same template, on its own budget (`agents.code_review_max_fix_loops`) — the
HIGH-finding posture and the post-fix re-validation rule live there.

## Stage 5.9 — Cleanup pass

**Opt-in, permanently OFF by default.** ON only via `pipeline.cleanup.enabled: true` or
`--cleanup`; `--no-cleanup` always wins OFF. Auto-off when Stage 5 isn't green, `implement` was
skipped, or the diff touched no code surface. When OFF, append `cleanup` to
`run.json.stages_skipped` (reason in `data.skip_reasons.cleanup`) and skip to Stage 6 — do not load the template. When ON, **read
`skills/sdlc/templates/stage-5.9-cleanup.md` now** (two-lens fan-out, `safe_to_apply` rubric).

## Stage 6 — Hand off (no commit, no git writes)

`/sdlc` runs the full pipeline and then **stops at the edge of git**; the user reviews
the validated working tree and commits it themselves. Do NOT run `git add`, `git commit`,
`git checkout -b`, `git push`, `gh pr create`, or `/review` — leave the working tree exactly
as the pipeline produced it.

**Read `skills/sdlc/templates/stage-6-handoff.md` now** and run it. It carries the secret
scan, the diff report and suggested commit message, gotcha capture and the seam sentinel,
the `TASKS.md` close-out and re-entry rows (reported, not written, under `pipeline.tasks.writer: "orchestrator"`), and
the terminal state write.

## Stage 7 — Report

**Degrade check (Claude only).** Skip it, printing `degrade check: skipped (run predates it)`, when `run.json.args.toolkit_version` is absent. Otherwise, if `implement` is in `stages_completed` and the Stage 2 sidecar
for the path taken — `implement.json` (single-agent) or `converge.json` (decomposed,
`run.json.data.stage2_decomposed: true`) — is missing or lacks `data.dispatch`, the orchestrator
did the work itself: after Stage 6's terminal write, write `run.json.data.degraded = {reason, missing}` and print `DEGRADED: <reason> — missing
<what>` as the first line of the report. Leave `status` alone. Never load
`stage-5.7-review-fix.md` for this.

**Stage table.** Print one table: each stage as `ran` (in `stages_completed`) or `skipped:
<reason>` (from `data.skip_reasons`).

**Read `skills/sdlc/templates/stage-7-report.md` now** for the summary: branch, files changed,
suggested commit message (no `Co-Authored-By` unless `coauthor_trailer` is literally `true`),
eval / test / plan-check results, the always-printed `tasks:` line, and an explicit
statement that **nothing was committed** — the next move is the user's.

## Skill-repo mode (auto-detected)

Active when `.claude-plugin/marketplace.json` exists at repo root (detected at
Stage 0). The standard pipeline is shaped for "code-with-tests"; a skill repo has
no test surface, so the eval-driven stages are inapplicable. Three stages change;
every other stage runs unmodified.

| Stage | Skill-repo behavior |
|---|---|
| Stage 3 — Generate evals | **skip** (no test surface) — append `generate-evals` to `run.json.stages_skipped`, `data.skip_reasons.generate-evals: "skill repo, no test surface"` |
| Stage 5 — Validate | **substitute the test half only** with `skills/sdlc/templates/stage-5-skill-repo.md` (HARD: validator, marketplace registration, template-reference resolution, setup.sh dry install; SOFT: line-count ceiling, README skills-table drift, overlay parity) — **the plan-vs-diff check stays on** whenever there is a plan target: requirements gate as normal, flow is advisory-only (no test evidence to witness it). Writes `validate.json` with `data.mode = "skill-repo"` |
| Stage 5.7 — Adversarial review | **adapt when enabled, never self-skip** — still opt-in/OFF-by-default per Stage 5.7 above; when it's ON, a docs-only diff is the code surface here. Correctness and plan-alignment apply equally to prose; `security` applies its skill-repo shell-injection check; `config-env-docs` repoints to the frontmatter / marketplace / template-reference checks in `stage-5-skill-repo.md` |

## Gotchas

- **Stage 5's plan check runs whenever there's a plan to check** — pass a plan
  file (or a task with `parent_plan`) and they run unconditionally. They skip
  only when there is literally no plan target to validate against — never
  behind a separate opt-in flag or frontmatter knob.
- **Don't fork the shared templates.** Stage bodies live once in
  `skills/sdlc/templates/`; edit the template, never copy it into this file.
  Zero template duplication is the contract.
- **Range accumulates in the tree.** A range runs the pipeline over each task
  and leaves all changes uncommitted together; you choose how to slice the
  commits when you review.
