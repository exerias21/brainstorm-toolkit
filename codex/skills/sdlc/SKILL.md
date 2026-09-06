---
name: sdlc
description: >
  Run the full SDLC pipeline on a plan file, task id, task range (e.g. "1-5"),
  or an ad-hoc description: sanity-check -> implement -> evals -> fix ->
  validate -> flowsim, then hand off the validated changes for you to commit.
  No commit, no branch, no push, no PR. Codex overlay of the canonical skill --
  every stage runs inline (sequential, no parallel sub-agents). Use /task instead for a
  single small TDD fix with no plan.
metadata:
  brainstorm-toolkit-applies-to: codex
---

# sdlc (Codex Edition — Sequential)

Sequential Codex edition — every stage runs inline rather than as a parallel dispatch. Same
stages, same shared templates, same terminal action: **no git writes** — it hands you a
validated tree to commit.

**Model-tier cap** (`models.cap` in `project.json`, or `--model <tier>`; flag > config > default — see `skills/sdlc/templates/models.md`) is honored wherever sub-agents are dispatched. **The cap is advisory on this runtime** (why: *Runtime regimes* in `models.md`) — set your session model to the cap tier for the savings.

> **`skills/sdlc/templates/*` paths below are real, installed files on this runtime.**
> `setup.sh` ships that shared template tree alongside the skills and rewrites the citation
> prefix, so open the templates the stages name rather than relying on anything inlined here.

Every sub-agent dispatch in the templates below runs **inline in this session** on this
runtime. Keep the discipline the dispatch enforced: report only the structured summary,
never paste raw tool or runner output into your context.

## When to use

| Skill | Input | Terminal action |
|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red-green → commit only if you ask |
| `/sdlc <plan \| task-id \| range \| desc>` | plan, task(s), or ask | full pipeline → validated changes left for you to commit |

Stage bodies live once in the shared `skills/sdlc/templates/` tree; this overlay
adds no new templates and no new schema beyond `run.json.pipeline = "sdlc"`
and a `handoff.json` sidecar at Stage 6.

## Prerequisites

- You are on the branch the changes should land on. This skill never switches
  branches and never commits.
- `.claude/project.json` optional. The eval stage and Stage 5's plan check +
  flowsim flow trace skip silently when their config or a plan target is absent.

## Output verbosity (default: quiet)

**Read `skills/sdlc/templates/output-verbosity.md` now.** Same contract as every runtime:
one line per stage, one summary table at the end, no intermediate narration. Always printed
regardless of verbosity — the per-dispatch `model:` line, gate verdicts, PAUSE blocks, the
`Next:` seam line, and warnings.

## Stage 0 — Resolve input

- **Plan file** (path ending `.md` that exists) → use as the plan, like `/sdlc`.
  **Also scan `TASKS.md` for `Active / Pending` rows referencing this plan** — by the
  `_plan: <slug>_` marker `/brainstorm` appends, falling back to the `— plans/<slug>.md`
  path for legacy untagged rows — and mark them `[~]`. Stage 6's close-out flips them via
  `scripts/close-tasks.sh`. Without this scan the close-out has nothing to resolve, which
  is why a finished plan used to close nothing on this runtime. A run matching no rows
  updates no `TASKS.md` — expected, not a miss.
**If `.claude/project.json` is absent while `project.json.example` is present, warn once
here** — every gated setting (`models.cap`, `pipeline.*`, test commands) is silently inert
and the run reports `cap: none`.

- **Task id** (`task-NNN` or a row number) → read that row + linked task file;
  its `parent_plan:` becomes the Stage 5 plan target.
- **Task range** (`N-M`, `task-N..task-M`, `tasks N-M`) → resolve every
  `Active / Pending` row in range; execute as a batch (changes accumulate in the
  working tree — see Stage 6 range semantics; this skill never commits). Record
  the resolved ids in `run.json.data.task_range`.
- **Ad-hoc description** → create a new row + task file via `/task`'s procedure.
  No plan, so Stage 5's plan check self-skips.

**Task-id / range / ad-hoc runs have no `_plan:` key** — that tag exists only on plan-file
rows — so Stage 6 cannot close them by key. **Persist the resolved row id(s) at Stage 0**
into `run.json.data.tasks.resolved[]`, one entry per row, each a substring unique to that
row (its linked `plans/tasks/task-N-<slug>.md` path is the natural choice). Stage 6 closes
exactly those entries via `scripts/close-tasks.sh close --scope resolved --ids-file`, never
a fuzzy match. Skip this and the row is marked `[~]` here and never closed — the same
close-out failure the plan-file scan above exists to prevent.
- **`--queue [N]`** → resolve this flag first; on any other input skip without opening the
  template. When it *is* `--queue`, **read `skills/sdlc/templates/queue-mode.md` now** and run
  it (selection, per-item slug, stop conditions, re-scan, park protocol and its mandatory
  sentinel). Codex's `PostCompact` reseed hook (`.codex/hooks.json`) keeps
  auto-compaction lossless for a long loop; escalations in `docs/LOOP-HYGIENE.md` (plugin repo).

Mark resolved rows `[~]`. Derive `slug`: the plan filename minus its extension, minus a leading
`brainstorm-` / `team-brainstorm-` / `pbi-NNN-` / `task-NNN-` prefix, lowercased, every character
outside `[a-z0-9-]` replaced with `-`, runs collapsed, ends trimmed; it must match
`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` or the run stops with a clear error (maintainer record:
`docs/CONVENTIONS.md`). Capture
`base_commit = git rev-parse HEAD` and initialize `.claude/pipeline/<slug>/`
with `pipeline: "sdlc"`, `base_commit`, `status: "in_progress"`, **and the
computed required fields that get dropped otherwise (DQ6):**
`plan_hash: "sha256:$(sha256sum <plan> | cut -d' ' -f1)"`, `started_at` = `updated_at`
= `"$(date -u +%Y-%m-%dT%H:%M:%SZ)"`. Omitting them breaks `--resume` + staleness detection.

**Then parse the plan.** Read the resolved plan/task file(s) fully and extract the feature
name, the implementation steps (numbered lists with file paths, or checkbox rows), the files to
create or modify, the acceptance criteria ("expected"/"should"/"must"/"verify" language) and
cross-module touchpoints. **Write `stage-outputs/parse.json`** with `data.feature_name`,
`data.files_to_change`, `data.implementation_step_count`, `data.acceptance_criteria_count` and
append `parse` to `run.json.stages_completed` — Stage 2's gate reads it and cannot run without it.

**Skill-repo detection** (automatic): if `.claude-plugin/marketplace.json` exists at repo root,
switch to **Skill-repo mode** below for the rest of the run. **Vendored-skill guard:** if it is
absent but the plan's changed files target `.claude/skills/**`, `.github/skills/**` or
`.agents/skills/**`, **stop and report** — those edits belong upstream in the canonical toolkit
repo, not in a consumer's pipeline.


**`--resume`:** if `--resume` was passed, read the existing `run.json` instead of
re-initializing — reject on a `plan_hash` mismatch, skip stages whose sidecar shows
`status: "pass"`, and resume at the first non-passing one (follows `/sdlc`'s
Resumption rules; error if there's no prior run).

**Continuity detection** (prompt, never auto) — same logic as `/sdlc`: **skip
entirely on the `main_branch`** (merges make every run an ancestor there — pure
noise). On a feature branch, take only the **single most-recently-updated** run
whose `base_commit` is an ancestor of HEAD, and prompt **only** if it's
non-terminal OR complete with HEAD advanced past its recorded `base_commit`
(a follow-up landed outside the pipeline). One prompt at most, or none.

## Stage 1.5 — Sanity check

Run `/sdlc` Stage 1.5 inline (sequential pre-flight). Not gated, not optional.
For a range, run once over the combined set. Stop and report on a real blocker.
`agents.sanity_focuses` selects which checks run (default all three); on this
runtime `models.sanity` is advisory like every tier — set your session
model instead.

## Stage 2 — Implement

**Runtime note — why there is no delegation rule here.** The canonical `/sdlc` forbids the
orchestrator from calling Write/Edit during Stage 2, because on Claude the implement work
belongs in a sub-agent whose context is discarded. **This runtime has no sub-agent seam**, so
that rule cannot apply: you *are* the implementer and you must write the files. The cost it
guards against is real here too, though, and the mitigation is different — keep the session
short and hand off at stage boundaries (`docs/LOOP-HYGIENE.md`), because every file you write
stays in your context for the rest of the run.


Run `/sdlc` Stage 2 inline, including its **auto-gate** (**read
`skills/sdlc/templates/stage-2-gate.md` now**), preceded by **live-code grounding**.

**Live-code grounding** — **read `skills/sdlc/templates/convention-grounding.md` now** and follow it before writing any file. Scope the recon to the feature's target area, never the whole repo.

## Stage 3 — Generate evals

**Skip silently if no `eval.runner` is configured** — record
`data.skipped_reason: "no eval.runner"` and move on. Otherwise **read
`skills/sdlc/templates/stage-3-evals.md` now** and run it inline.

## Shared fix loop

At the first gate failure, **read `skills/sdlc/templates/fix-loop.md` now**: fix only the named
failures (no refactor), re-run the gate, 3 iterations max, then emit its PAUSE block and set
`run.json.status = "paused"`. Stage 5.7/5.8 has its own separate budget.

## Stage 5 — Validate (one stage)

**Read `skills/sdlc/templates/stage-5-validate.md` now** and run it. Two runtime deltas: there
is no `test-runner` sub-agent here, so run the configured suites yourself and report only the
structured `{name, file, expected, actual}` per failure — never paste raw runner output into
your context; and the plan check runs as one inline pass rather than a dispatch.

Everything else is identical, including the rule that matters most here: **the flow axis gates
only when witnessed.** With no test evidence from step 1, flow findings are advisory — they
cannot fail the stage or open the fix loop. The requirements axis gates either way.

## Stages 5.7 / 5.8 — Adversarial review + fix loop

**Opt-in, permanently OFF by default.** Activates only on an explicit `--review-model <name>`
flag or an explicit `pipeline.review_fix.enabled: true`; `--no-review` always wins OFF. An
absent or `enabled: false` block means OFF.

Resolve that gate **before** opening anything. When it is OFF, append `review` to
`run.json.stages_skipped` and go to Stage 6 — do not load the template. When it is ON, **read
`skills/sdlc/templates/stage-5.7-review-fix.md` now** and run it with each lens as a sequential
inline pass instead of a parallel dispatch. Everything else — lens selection, the reviewer-model
axis, the verify pass, the circuit breaker, the `auto_fixable` rubric, the fix-loop modes and
budget, the oscillation guard — is the same, including the sidecar shapes at the end of that file.

## Stage 5.9 — Cleanup pass

**Opt-in, OFF by default** (`pipeline.cleanup.enabled: true` / `--cleanup`; `--no-cleanup` wins
OFF; auto-off if Stage 5 isn't green, `implement` skipped, or no code surface touched — append
`cleanup` to `stages_skipped`). Else **read `skills/sdlc/templates/stage-5.9-cleanup.md` now**.

## Stage 6 — Hand off (no commit, no git writes)

Run the full pipeline, then **stop at the edge of git**. Do NOT run `git add`, `git commit`,
`git checkout -b`, `git push`, `gh pr create`, or `/review` — leave the working tree exactly
as the pipeline produced it. You review and commit.

**Read `skills/sdlc/templates/stage-6-handoff.md` now** and run it inline (no sub-agent seam
on this runtime — the secret scan and the gotcha capture protocol both run in-session; gotcha's
canonical skill is `skills/gotcha/SKILL.md`, installed here at `.agents/skills/gotcha/SKILL.md`).
It carries the diff report and suggested commit message, the `TASKS.md` close-out and re-entry
rows, and the terminal state write.

## Stage 7 — Report

Summarize: branch the changes sit on (uncommitted), files changed, suggested
commit message, eval pass/fail, test-check summary, the Stage 5 plan check —
requirements verdict plus the flowsim flow trace and whether it was witnessed or
advisory (or "skipped — no plan target") — and anything left open. **Always print
`tasks: N closed, M moved (K matched)`** from Stage 6's `handoff.json` `data.tasks`,
including `tasks: 0 closed (0 matched)` when nothing matched — that line is what turns a
silent close-out miss into a visible one; when `unmatched` is non-empty add
`(U unmatched — see /sdlc-status --reconcile)`. If the delivered diff
departs from the plan (a step skipped, reordered, or solved differently), say where and why in
one line each — the `plan-conformance-validator`'s partial/missing rows are the source. Make clear **nothing
was committed** — the next move is yours.

## Skill-repo mode (auto-detected)

Active when `.claude-plugin/marketplace.json` exists at repo root. A skill repo has no test
surface, so three stages change; every other stage runs unmodified.

| Stage | Skill-repo behavior |
|---|---|
| Stage 3 — Generate evals | **skip** — append `generate-evals` to `run.json.stages_skipped` |
| Stage 5 — Validate | **substitute** `skills/sdlc/templates/stage-5-skill-repo.md` (validator, marketplace registration, template-reference resolution, setup.sh dry install; soft: line ceilings, README drift, overlay parity). Writes `validate.json` with `data.mode = "skill-repo"` |
| Stage 5.7 — Adversarial review | **adapt, never self-skip** — a docs-only diff is the code surface here |

## Safety rules

- **Stop on ambiguity** — unclear plan steps: pause and ask.
- **Stop on repeated failures** — a fix loop that exhausts its budget reports rather than grinding.
- **Don't fix pre-existing failures** — only what this run introduced; `preexisting[]` is reported, never gated on.
- **Autonomy overrides interactive output styles** — the explicit invocation wins; run autonomously.

## Gotchas

- **Does no git writes.** No commit, branch, push, PR, or `/review`. Hands you
  a validated tree; you commit.
- **Stage 5's plan check runs whenever there's a plan to check.** It skips only
  when there is no plan target — not behind a frontmatter knob.
- **Don't fork the shared templates.** Stage bodies live once in
  `skills/sdlc/templates/`; edit the template, never copy it here.
- **Range accumulates in the tree** — all tasks' changes land uncommitted
  together; you slice the commits.
