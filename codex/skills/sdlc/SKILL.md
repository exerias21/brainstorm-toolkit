---
name: sdlc
description: >
  Run the full SDLC pipeline on a plan file, task id, task range (e.g. "1-5"),
  or an ad-hoc description: sanity-check -> implement -> evals -> fix ->
  validate -> flowsim, then hand off the validated changes for you to commit.
  No commit, no branch, no push, no PR. Codex overlay of the canonical skill --
  every stage runs inline (sequential, no parallel sub-agents). Use /task instead for a
  single small TDD fix with no plan.
argument-hint: "<plan-file | task-id | task-range | description> [--resume] [--queue [N]]"
metadata:
  brainstorm-toolkit-applies-to: codex
disable-model-invocation: true
---

# sdlc (Codex Edition — Sequential)

Sequential Codex edition. The canonical skill uses parallel agent dispatch for the
sanity-check on Claude; this overlay runs every stage inline, because Codex CLI's 2026
Agent Skills spec doesn't drive that fan-out. (Codex has native subagents and its own
plan mode; what it lacks is a usable per-subagent model override — see the cap note
below.) This overlay tracks the Copilot one closely; tune independently if Codex
behavior diverges. Same stages, same shared templates, same terminal action: **no git
writes** — it hands you a validated tree to commit.

**Model-tier cap** (`models.cap` in `project.json`, or `--model <tier>`; flag > config > default — see `skills/sdlc/templates/models.md`, a plugin-repo citation) is honored wherever sub-agents are dispatched. **The cap is advisory on this runtime** — set your session model to the cap tier for the savings.

> **Why advisory here is a Codex-specific story.** Codex *does* have native subagents (`.codex/agents/*.toml`, parallel, `max_threads`) — it is not structurally inline-only the way Copilot is. What blocks tiering is that **per-subagent model override is reported regressed upstream** (subagents inherit the parent model), so the Haiku/Sonnet fan-out runs single-model: functional, but with none of the per-stage cost savings. Reported 2026-07-13 from research, **not verified against a real Codex install**, and it may already be fixed — see the Codex entry under *Runtime regimes* in `models.md` before relying on it either way.

> **`skills/sdlc/templates/*` paths below are real, installed files on this runtime.**
> `setup.sh` ships that shared template tree alongside the skills and rewrites the citation
> prefix, so open the templates the stages name rather than relying on anything inlined here.

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
- **Task id** (`task-NNN` or a row number) → read that row + linked task file;
  its `parent_plan:` becomes the Stage 5 plan target.
- **Task range** (`N-M`, `task-N..task-M`, `tasks N-M`) → resolve every
  `Active / Pending` row in range; execute as a batch (changes accumulate in the
  working tree — see Stage 6 range semantics; this skill never commits). Record
  the resolved ids in `run.json.data.task_range`.
- **Ad-hoc description** → create a new row + task file via `/task`'s procedure.
  No plan, so Stage 5's plan check self-skips.
- **`--queue [N]`** (attended backlog loop) → select `Active / Pending` rows by
  priority (top `N` or `pipeline.loop.max_items`, default 5; `P1>P2>P3`, `[~]`
  first) and loop the pipeline over them, **re-scanning `TASKS.md` between items**
  so rows added mid-run join the loop. Stop conditions (`pipeline.loop.*`): a
  `paused`/`failed` item **parks** the loop (write its `/sdlc-status` hint to
  `.claude/.next-action`), a `confirm:true` next action parks it, and
  `max_items` / `max_consecutive_failures` (default 2) bound it. **No git writes;
  every park is a written next-action, never a dead end.** Each item's envelope
  stays **canonical** (`state-schema.md`: `feature_slug`/`plan_file` keys, required
  fields, canonical stage names — never `slug`/`plan` or `phase-*` stages; queue/phase
  data goes in `data.*`) with a **distinct per-item slug** `<plan-slug>-<row-id>` (never
  the shared plan slug — items would collide on one envelope dir). On park: set
  `run.json.status = "paused"` + `run.json.next_action = {cmd, confirm}`, **and — mandatory,
  don't skip it —** append the sentinel line:
  `line='{"cmd":"/sdlc <plan> --queue","source":"sdlc","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
  (plus a `confirm:true` line for the confirm action if it parked on one). The **sentinel is
  the ONLY thing the Stop hook surfaces**; `run.json.next_action` alone is invisible, so a park
  that sets only the envelope field leaves the loop dead.
- **Long runs — context hygiene:** a many-hour loop accumulates context in the one orchestrator
  session. Codex's `PostCompact` reseed hook (shipped via `.codex/hooks.json`) keeps auto-compaction
  lossless for the loop; config knobs + the fresh-`codex exec`-per-item escalation are in
  `docs/LOOP-HYGIENE.md` (plugin repo).

Mark resolved rows `[~]`. Derive `slug` per `docs/CONVENTIONS.md`. Capture
`base_commit = git rev-parse HEAD` and initialize `.claude/pipeline/<slug>/`
with `pipeline: "sdlc"`, `base_commit`, `status: "in_progress"`, **and the
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
   `line='{"cmd":"/gotcha <drafted text>","source":"sdlc","confirm":false}'; grep -qF "$line" .claude/.next-action 2>/dev/null || echo "$line" >> .claude/.next-action`
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
   and a `- [ ] (P2) verify {feature-slug} deployed — `/repo-health` plans/{feature-slug}.md`
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
`/repo-health` and `/sdlc-status` will (correctly) flag it as a stale run. **Also set
`run.json.next_action = {cmd, confirm}`** (L8) to the proposed follow-up
(`/repo-health` on complete; `/sdlc-status` on pause) so
`/sdlc-status` recovers the handoff after the sentinel fires; omit when there's none. This holds
for **retro / validation-only runs** too (Stage 2 skipped because the code
already landed): advance `run.json.stage`/`stages_completed` as each validation
sidecar is written, add `implement` to `stages_skipped`, and close on a terminal
`status` — never leave a `parse`-stage envelope `in_progress` with sidecars
already on disk.

## Stage 7 — Report

Summarize: branch the changes sit on (uncommitted), files changed, suggested
commit message, eval pass/fail, test-check summary, the Stage 5 plan check —
requirements verdict plus the flowsim flow trace and whether it was witnessed or
advisory (or "skipped — no plan target") — and anything left open. Make clear **nothing was
committed** — the next move is yours.

## Gotchas

- **Does no git writes.** No commit, branch, push, PR, or `/review`. Hands you
  a validated tree; you commit. Only `/sdlc` touches git history.
- **Stage 5's plan check runs whenever there's a plan to check.**
  when there is no plan target — not behind a frontmatter knob.
- **Don't fork the shared templates.** Stage bodies live once in
  `skills/sdlc/templates/`; edit the template, never copy it here.
- **Range accumulates in the tree** — all tasks' changes land uncommitted
  together; you slice the commits.
