---
name: sdlc-lite
description: >
  Sequential full-pipeline-minus-git skill for Codex CLI. Takes a plan file, a
  task id, a task range (e.g. "1-5"), or an ad-hoc description; runs
  implement → evals → validate → plan-validate → flowsim; then hands off the
  validated changes for you to commit. No commit, no branch, no push, no PR.
  Codex-optimized overlay of canonical /sdlc-lite — every stage runs inline
  (no parallel sub-agents, no Plan mode). Same stages as /sdlc; only /sdlc
  touches git.
argument-hint: "<plan-file | task-id | task-range | description> [--resume] [--queue [N]]"
metadata:
  brainstorm-toolkit-applies-to: codex
disable-model-invocation: true
---

# sdlc-lite (Codex Edition — Sequential)

Sequential version of `/sdlc-lite`. Canonical `/sdlc-lite` uses parallel agent
dispatch for the sanity-check and Stage 5.5 validators on Claude; this overlay
runs every stage inline. Codex CLI's 2026 Agent Skills spec, like Copilot's,
doesn't yet support parallel sub-agent dispatch. This overlay tracks the Copilot
one closely; tune independently if Codex behavior diverges. Same stages as
`/sdlc`; the only difference is Stage 6 — `/sdlc-lite` does **no git writes**
(hands you a validated tree to commit), while `/sdlc` commits + opens a PR.

**Model-tier cap** (`models.cap` in `project.json`, or `--model <tier>`; flag > config > default — see `skills/sdlc/templates/model-cap.md`) is honored wherever sub-agents are dispatched. On this runtime every stage runs inline in the session model, so the cap is advisory here — set your session model to the cap tier for the savings.

> **`skills/sdlc/templates/*` paths below are citations into the brainstorm-toolkit
> plugin repo — they are NOT installed on this runtime.** Overlays replace the canonical
> skill tree wholesale, so `.agents/skills/sdlc/` ships `SKILL.md` only. Do not try to
> open them; everything this overlay needs to execute is inlined here. Read them in the
> plugin repo only if you are changing the contract itself.

## When to use

| Skill | Input | Terminal action |
|---|---|---|
| `/task <description>` | ad-hoc ask | TDD red-green → commit only if you ask |
| `/sdlc-lite <plan \| task-id \| range \| desc>` | plan, task(s), or ask | full pipeline → validated changes left for you to commit |
| `/sdlc <plan-file>` | plan file | full pipeline → commit + PR |

Reuses `/sdlc`'s stage templates and state envelope verbatim — no new
templates, no new schema beyond `run.json.pipeline = "sdlc-lite"` and a
`handoff.json` sidecar at Stage 6.

## Prerequisites

- You are on the branch the changes should land on. This skill never switches
  branches and never commits.
- `.claude/project.json` optional. Eval / validate / flowsim skip silently when
  their config or a plan target is absent.

## Stage 0 — Resolve input

- **Plan file** (path ending `.md` that exists) → use as the plan, like `/sdlc`.
- **Task id** (`task-NNN` or a row number) → read that row + linked task file;
  its `parent_plan:` becomes the flowsim/plan-validate target.
- **Task range** (`N-M`, `task-N..task-M`, `tasks N-M`) → resolve every
  `Active / Pending` row in range; execute as a batch (changes accumulate in the
  working tree — see Stage 6 range semantics; this skill never commits). Record
  the resolved ids in `run.json.data.task_range`.
- **Ad-hoc description** → create a new row + task file via `/task`'s procedure.
  No plan, so plan-validate/flowsim self-skip (Stage 5.5/5.6).
- **`--queue [N]`** (attended backlog loop) → select `Active / Pending` rows by
  priority (top `N` or `pipeline.loop.max_items`, default 5; `P1>P2>P3`, `[~]`
  first) and loop the pipeline over them, **re-scanning `TASKS.md` between items**
  so rows added mid-run join the loop. Stop conditions (`pipeline.loop.*`): a
  `paused`/`failed` item **parks** the loop (write its `/triage <slug>` hint to
  `.claude/.next-action`), a `confirm:true` next action parks it, and
  `max_items` / `max_consecutive_failures` (default 2) bound it. **No git writes;
  every park is a written next-action, never a dead end.** Each item's envelope
  stays **canonical** (`state-schema.md`: `feature_slug`/`plan_file` keys, required
  fields, canonical stage names — never `slug`/`plan` or `phase-*` stages; queue/phase
  data goes in `data.*`) with a **distinct per-item slug** `<plan-slug>-<row-id>` (never
  the shared plan slug — items would collide on one envelope dir). On park: set
  `run.json.status = "paused"` + `run.json.next_action = {cmd, confirm}`, **and — mandatory,
  don't skip it —** append the sentinel line:
  `line='{"cmd":"/sdlc-lite <plan> --queue","source":"sdlc-lite","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
  (plus a `confirm:true` line for the confirm action if it parked on one). The **sentinel is
  the ONLY thing the Stop hook surfaces**; `run.json.next_action` alone is invisible, so a park
  that sets only the envelope field leaves the loop dead.
- **Long runs — context hygiene:** a many-hour loop accumulates context in the one orchestrator
  session. Codex's `PostCompact` reseed hook (shipped via `.codex/hooks.json`) keeps auto-compaction
  lossless for the loop; config knobs + the fresh-`codex exec`-per-item escalation are in
  `docs/LOOP-HYGIENE.md` (plugin repo).

Mark resolved rows `[~]`. Derive `slug` per `docs/CONVENTIONS.md`. Capture
`base_commit = git rev-parse HEAD` and initialize `.claude/pipeline/<slug>/`
with `pipeline: "sdlc-lite"`, `base_commit`, `status: "in_progress"`, **and the
computed required fields that get dropped otherwise (DQ6):**
`plan_hash: "sha256:$(sha256sum <plan> | cut -d' ' -f1)"`, `started_at` = `updated_at`
= `"$(date -u +%Y-%m-%dT%H:%M:%SZ)"`. Omitting them breaks `--resume` + staleness detection.

**`--resume`:** if `--resume` was passed, read the existing `run.json` instead of
re-initializing — reject on a `plan_hash` mismatch, skip stages whose sidecar shows
`status: "pass"`, and resume at the first non-passing one (follows `/sdlc`'s
Resumption rules; error if there's no prior run).

**Continuity detection** (prompt, never auto) — same logic as `/sdlc`: **skip
entirely on the `main_branch`** (merges make every run an ancestor there — pure
noise). On a feature branch, take only the **single most-recently-updated** run
whose `base_commit` is an ancestor of HEAD, and prompt **only** if it's
non-terminal OR complete with HEAD advanced past its recorded `commit_sha`
(a follow-up landed outside the pipeline). One prompt at most, or none.

## Stage 1.5 — Sanity check

Run `/sdlc` Stage 1.5 inline (sequential pre-flight). Not gated, not optional.
For a range, run once over the combined set. Stop and report on a real blocker.

## Stage 2 — Implement

Run `/sdlc` Stage 2 inline, including its **auto-gate** (see
`.agents/skills/sdlc/SKILL.md`), preceded by **live-code grounding**.

**Live-code grounding** (inlined from `skills/sdlc/templates/convention-grounding.md`;
scope the recon to the feature's target area, never the whole repo):

1. Find the **2–3 closest existing implementations** of the same kind of thing (another
   route, migration, component, CLI command) by grep/glob — let the code, not memory,
   tell you the shape.
2. Extract their patterns with `path:line` citations: where this kind of code lives,
   naming, error/logging shape, the data-access seam, dependency + import conventions,
   test layout.
3. Read `AGENTS.md` / `CLAUDE.md` / `GOTCHAS.md` / `.claude/project.json` as *stated
   intent only*. **Where a doc and the live code disagree, the code wins** — record it on
   the `Doc drift` line and make it actionable in the Stage 6 hand-off (nudge `/gotcha`
   if it is a genuine trap).
4. Prefer extending an existing module/helper/type over adding a parallel one; introduce
   a new pattern only when none fits, and say why.

Honor any `## Conventions & reuse` block already in the plan, re-verifying it against live
code (the code may have moved since the plan was written). A plan with no reuse and no
justified new pattern is a red flag — it usually means the recon was skipped.

Compute `surfaces_touched` (planned files vs.
the surface globs) and `task_count` (step count). **Decompose iff**
`surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` (default `6`,
override via `pipeline.decompose_min_tasks`) AND the per-surface file sets are
disjoint.

- **Single-pass (default):** execute the plan/task steps inline, in order. No
  worker handoff. Follow the `Files` section (fill it in as you go).
- **Decompose (large multi-surface plan):** split the files into disjoint lanes
  (data / backend / frontend / docs) with a per-lane interface contract,
  implement each lane in dependency order (one fully before the next, editing
  only that lane's files and coding against the contract), then converge —
  reconcile imports / call sites / shared types and sweep for unresolved imports
  or symbol collisions. Record `stage2_decomposed` + `lanes` and write
  `decompose.json` / `implement-<lane>.json` / `converge.json`.

For a task range the gate sees the combined file/step set. After implementing,
run `git diff --stat` and confirm expected files were touched. Stop on any
blocker.

## Stage 3 — Generate evals

Same procedure as `/sdlc` Stage 3 (see `.agents/skills/sdlc/SKILL.md`):
- new Python pure functions → `tests/eval/test_{slug}_eval.py`,
- scripts with `--input` fixtures → `<eval.features_dir>/{slug}/`,
- no testable surface → note and proceed.

**Skip silently if no `eval.runner` is configured.**

## Stage 4 — Eval + sequential fix loop

Run `<eval.runner> --feature {slug} --output json`. Fix failures inline.
3-iteration budget. On persistent failure: pause with a **Diagnosis** — name the
failure class (flaky / code-defect / plan-wrong / config-missing) and ONE
recommended command (flaky → re-run the gate; code-defect → `/task fix: <failure>`;
plan-wrong → `/brainstorm` the failing step; config-missing → set it in
`.claude/project.json`) — fastest path is `/triage <slug>` (classifies + drafts the
fix); or fix manually and re-run `/sdlc-lite <input> --resume` (reuses the green
stages; fresh run if you edited the plan). Skip when Stage 3 was skipped.

## Stage 5 — Validate

Invoke `/test-check`. Route new failures through the Stage 4 fix loop (same
3-iteration budget). Pre-existing failures: note and skip.

## Stage 5.5 — Plan requirements validation

Run when a **plan target** exists (plan-file input, or task with `parent_plan`):
re-read the plan, verify each requirement is fulfilled, flag failures, route
findings through the Stage 4 fix loop. **Skip with a note when there is no plan
target** — nothing to validate against, not an arbitrary gate.

`pipeline.plan_validate.model` (`haiku|sonnet|opus`) sets how strong a reader judges
the plan here; it is still bounded by the model cap, which can only lower it.

## Stage 5.6 — Flowsim

Same condition as 5.5: when a plan target exists, invoke `/flowsim <plan-target>`
and process results per `/sdlc` Stage 5.6; mismatches feed the Stage 4 fix loop.
Skip with a note when none exists.

## Stage 5.7 — Adversarial review (inline, sequential)

**Opt-in, permanently — never runs by default.** Runs after Stage 5.6 flowsim, before Stage 6,
only when explicitly turned on this run (`--review-model <name>`, or an explicit
`pipeline.review_fix.enabled: true`; default reviewer `opus` once enabled — see
`skills/sdlc/templates/review-model.md`). An omitted `pipeline.review_fix` block, or
`enabled` left unset, means OFF — there is no default-on flip. Skipped when not opted in,
`--no-review` was passed, `pipeline.review_fix.enabled: false`, or the changed-files-gate reports a
docs-only diff — **unless a `.claude-plugin/marketplace.json` exists at the repo root**, in which
case this is a
skill repo, `.md` skill files ARE the code surface (there is no separate `.env`/compose surface to
gate on here), and this docs-only self-skip does not apply — Stage 5.7 runs, with the
config/env/docs lens repointed to `skills/sdlc/templates/stage-5-skill-repo.md`'s structural checks in place of
env/compose checks. (This mirrors D6 / plan §5.3 gate 1's exemption on the canonical/Workflow side;
this overlay runtime has no other skill-repo detection of its own, so the marketplace-manifest
check above IS its skill-repo signal.)

**No parallel sub-agents on this runtime.** Run each of the four lenses — correctness,
plan⇌code alignment, config/env/docs consistency, security (checklists:
`skills/sdlc/templates/review-correctness-checklist.md` + `skills/sdlc/templates/review-security-checklist.md`) — as one sequential inline pass over the
diff, re-reading it fresh for each lens. If a genuinely separate reviewer integration is
configured and reachable (e.g. an MCP tool exposing Fable), call it once per lens instead of
self-reviewing; otherwise review under an adversarial persona in the session model itself and say
explicitly in the Stage 7 report which mode ran.

Collect findings (`{severity, file:line, defect, failure_scenario, fix}`), then run one
adversarially-skeptical, evidence-required verify pass (default-refute: drop anything not
independently confirmable from the diff). Write `stage-outputs/review.json`. Zero confirmed
findings → skip Stage 5.8.

**False-positive circuit breaker.** Even though this runtime reviews inline with no sub-agent seam,
it still updates the same cross-run ledger, `.claude/pipeline/_review-stats.json`: after each run,
append this run's raw/confirmed counts per lens and recompute demotion. A lens repeatedly producing
unconfirmable findings is auto-demoted from dispatch (skipped, and recorded in
`review.json.data.demoted_lenses`) until 5 consecutive runs at ≥60% confirmed-rate re-promote it.

## Stage 5.8 — Fix-prompt generation + approve loop

For confirmed findings, draft a structured fix spec per finding, applying the auto_fixable rubric
(a bug fixing an explicit contract vs. a product/design decision — see
`skills/sdlc/templates/review-model.md`). Per `pipeline.review_fix.mode` (default `interactive`):
- **`interactive`**: present each fix spec for approve / edit / skip. Approved specs run through
  the existing Stage 2/4 implement+fix machinery inline, then a fresh adversarial re-review of the
  touched files (this loop iteration's own pass) decides whether another iteration is needed. Loop
  until clean or `max_fix_loops` (own budget, separate from the Stage 4 fix budget).
- **`auto`**: after `auto_approve_after` consecutive approvals, or confidence ≥
  `confidence_threshold`, apply and continue — EXCEPT `auto_fixable: false` findings (design
  decisions), which are always surfaced, never auto-applied.
- **`off`**: report only.

**Post-fix validation (once, after the loop exits — not per iteration):** if any fix was applied
this run, re-run the Stage 5 `validate` gate exactly once before Stage 6. A regression there pauses
the run for **both** `/sdlc` and `/sdlc-lite` — an objective test break, unlike the severity-gated
review-finding blocking below, stops both modes rather than handing off broken code (see the
canonical prose's "Post-fix validation").

Write a single `stage-outputs/review-fix.json` with `data.loops[]` (one entry per pass) — never
numbered `review-fix-<n>.json` files. `/sdlc-lite`'s posture is **warn-and-hand-off, not blocking**: a surviving high-severity confirmed
finding is reported prominently in the handoff report (consistent with the existing warn-only
secret scan) but does not prevent handoff — you decide whether to fix before committing.

## Stage 6 — Hand off (no commit, no git writes)

Run the full pipeline, then **stop at the edge of git**. No commit, branch,
push, PR, or `/review`. You review and commit.

1. Secret scan the changed files (gitleaks if available, regex-fallback
   otherwise). **Warn-only** — surface findings (file:line) but never block.
   HIGH findings get a `⚠ HIGH:` prefix; worth scrubbing before you commit.
2. **Report, don't commit.** Show `git diff --stat`, the files changed, and a
   suggested commit message. Do NOT run `git add`, `git commit`,
   `git checkout -b`, `git push`, `gh pr create`, or `/review`. Leave the tree
   as the pipeline produced it.
   ```
   Suggested (run yourself):
     git add <files>
     git commit -m "feat: <title>"
   ```
   **Range**: changes from all tasks accumulate in the tree; you slice the
   commits when you review.
3. **Capture at loop-exit + seam** — run the shared protocol in
   `.agents/skills/gotcha/SKILL.md` (canonical: `skills/gotcha/SKILL.md`).
   Auto-draft a gotcha entry **only** on an objective trigger — a fix-loop
   that **failed-then-recovered**, or the user voicing surprise — route it
   through gotcha's dedup, one-tap confirm. A clean run stays silent (no
   vibe-gating). If capture is **declined/deferred**, drop the seam
   sentinel — append ONE structured line deduped by `cmd` (see `docs/SEAM.md`):
   `line='{"cmd":"/gotcha <drafted text>","source":"sdlc-lite","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
   (never a bare `/gotcha`). Codex **does** have a Stop hook (`.codex/hooks.json`, shipped
   by the plugin / `setup.sh`) that surfaces this — but until it's wired **and the `.codex/`
   dir is trusted** (`/hooks`), also print an inline `Next: /gotcha <drafted text>` line in
   the Stage 7 report as the fallback, so the suggestion isn't silently lost.
4. Mark each resolved `TASKS.md` row `[x]`, move to `Done`, set
   `status: completed` in the task file(s) — work is done and validated; only
   the commit is left to you.
5. **Leave re-entry rows** so the queue keeps the follow-up: when a
   manifest/lockfile/Dockerfile changed (deploy-delta), append
   `- [ ] (P1) rebuild <env> for {feature-slug} (dependency change — rebuild, not restart) — plans/{feature-slug}.md`;
   and a `- [ ] (P2) verify {feature-slug} deployed — /post-deploy-verify plans/{feature-slug}.md`
   row closes the loop the same way `/sdlc` Stage 6 does.
   **Then print the manual-verification line** from `.claude/project.json` `stack.*` (all
   keys optional): `stack.rebuild` on the deploy-delta case (a dependency changed, so a
   plain restart runs stale code), otherwise `stack.up`; append `stack.url` when set.
   **Printed, never auto-run** — you asked for a validated tree, not a running one. If a
   needed key is absent, name the key instead of guessing a command.

Write `stage-outputs/handoff.json` =
`{branch, files_changed[], committed: false, suggested_commit_msg}`. **Always
set `run.json.status` to a terminal value** (`complete`, or `paused` if you
stopped mid-pipeline) before exiting — never leave it `in_progress`, or
`/repo-health` and `/status` will (correctly) flag it as a stale run. **Also set
`run.json.next_action = {cmd, confirm}`** (L8) to the proposed follow-up
(`/post-deploy-verify plans/<slug>.md` on complete; `/triage <slug>` on pause) so
`/next` recovers the handoff after the sentinel fires; omit when there's none. This holds
for **retro / validation-only runs** too (Stage 2 skipped because the code
already landed): advance `run.json.stage`/`stages_completed` as each validation
sidecar is written, add `implement` to `stages_skipped`, and close on a terminal
`status` — never leave a `parse`-stage envelope `in_progress` with sidecars
already on disk.

## Stage 7 — Report

Summarize: branch the changes sit on (uncommitted), files changed, suggested
commit message, eval pass/fail, test-check summary, flowsim status (or
"skipped — no plan target"), anything left open. Make clear **nothing was
committed** — the next move is yours.

## Gotchas

- **Does no git writes.** No commit, branch, push, PR, or `/review`. Hands you
  a validated tree; you commit. Only `/sdlc` touches git history.
- **flowsim/plan-validate run whenever there's a plan to check.** They skip only
  when there is no plan target — not behind a frontmatter knob.
- **Don't fork `/sdlc`'s templates.** If a stage needs different copy, it's a
  `/sdlc` job — re-invoke as `/sdlc`.
- **Range accumulates in the tree** — all tasks' changes land uncommitted
  together; you slice the commits.
