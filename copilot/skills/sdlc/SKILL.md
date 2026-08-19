---
name: sdlc
description: >
  Sequential plan-to-PR pipeline for Copilot. Takes a plan file, implements it,
  generates and runs evals, validates with /test-check, and creates a PR for
  human review. This is a Copilot-adapted version of the full SDLC skill —
  runs the same stages, but inline and sequentially (no parallel worker spawning).
  Use when you have a finalized plan in plans/ or TASKS.md and want the pipeline
  to drive the delivery.
argument-hint: "{plan_file} [--resume]"
metadata:
  brainstorm-toolkit-applies-to: copilot
disable-model-invocation: true
---

# SDLC Pipeline (Copilot Edition — Sequential)

Sequential version of the SDLC pipeline. Unlike the Claude Code canonical (which spawns Haiku/Opus/Sonnet workers in parallel), this overlay executes every stage inline: Copilot does the work itself, one stage at a time.

When Copilot's VS Code agent mode gains parallel worker support (Copilot CLI already has `/fleet`), this overlay can be upgraded. Today it ships as a useful degraded version — slower but complete.

**Model-tier cap** (`models.cap` in `project.json`, or `--model <tier>`; flag > config > default — see `skills/sdlc/templates/models.md`) is honored wherever sub-agents are dispatched. On this runtime every stage runs inline in the session model, so the cap is advisory here — set your session model to the cap tier for the savings.

## Prerequisites

- Plan file exists at the path you passed, OR you are pointing at TASKS.md.
- Git working tree is clean.
- `.claude/project.json` exists with at least `main_branch`; `test.*`, `logs.*`, and `eval.*` recommended so Stages 4–5 work.

## Output verbosity (default: quiet)

**Default `quiet`.** Stage narration is re-read by every later turn in the same
session, so it compounds. Print **one** line per stage —
`<stage> · <verdict> · model: <tier> (cap: <cap|none>)` — and one summary table at
the final report. No intermediate narration, no restating file contents, no
echoing a review pass's full output. Detail already lives in the
`stage-outputs/` sidecars, which are the durable record.

**Always printed regardless of verbosity:** the per-dispatch `model:` line, every
gate verdict, any PAUSE block, the `Next:` seam line, and warnings (config-presence,
reviewer-axis cost note, session-model nudge).

`pipeline.output.verbosity: "normal"` in `.claude/project.json` restores full
narration. A missing `project.json` means `quiet` — by design: the saving must not
depend on a file the repo may never have created.

**Config-presence check (once, at the first stage).** If `.claude/project.json` is
absent while `.claude/project.json.example` is present, warn once — every gated
setting (`models.cap`, `pipeline.*`, test commands) is silently inert.

## Stage 1 — Parse the plan

**`--resume`:** if `--resume` was passed, do NOT re-init a fresh envelope — read the
existing `.claude/pipeline/<slug>/run.json`, reject if the plan's `plan_hash` changed
since the paused run ("plan changed — start fresh"), skip every stage whose sidecar
shows `status: "pass"`, and resume at the first non-passing stage (follows `/sdlc`'s
canonical Resumption rules). If no prior run exists, error rather than starting fresh.

Read the plan file fully. Valid sources:
- `plans/brainstorm-<slug>.md` with Direction / Implementation Steps.
- `plans/tasks/task-N-<slug>.md` (a task file written by `/task`).
- `TASKS.md` at repo root — treat each `[ ]` or `[~]` row in Active / Pending as one step, follow linked task files for detail.

Extract:
- Feature name/slug (from filename or first heading).
- Implementation steps (numbered lists with file paths, or checkbox rows).
- Files to create or modify.
- Acceptance criteria ("expected", "should", "must", "verify" language).
- Cross-module touchpoints.

Report scope:

```
## SDLC Pipeline — {feature_name}
**Plan**: {plan_file}
**Files to change**: {count}
**Implementation steps**: {count}
**Acceptance criteria**: {count}
**Estimated complexity**: Small / Medium / Large
```

## Stage 1.5 — Sanity-check the plan (inline, sequential)

Before committing time to implementation, run the configured checks yourself — one pass
for each. `agents.sanity_focuses` in `.claude/project.json` selects which of the
three run (default: all). `models.sanity` is advisory on this runtime —
stages run inline in the session model, so set that instead.

**Check A — File path reality.** For every file path mentioned in the plan:
1. Verify the file exists (Glob or `ls`).
2. If the plan references a specific function, class, or symbol, grep for it.
3. If the plan says "follow the pattern in X", read X briefly and verify the description matches.
Flag anything missing or inconsistent.

**Check B — Completeness.** Look for common missing steps based on what the plan creates:
- New DB migration → does the plan mention running/applying it?
- New API endpoint → does it mention registering with the router / app?
- New frontend component → does it mention importing it in a parent?
- New config key or env var → documented?
- New DB table → indexes mentioned?
- New scheduled job → registered with the scheduler?

Infer the project's patterns from its README, CLAUDE.md, AGENTS.md, and existing code before flagging. Only flag a miss if the project would actually need that step.

**Check C — Gotchas.** Read `GOTCHAS.md` at repo root (path override in `gotchas_file` key of `.claude/project.json`). Cross-reference each plan step against every gotcha. For each step, flag any gotcha that applies with its prescribed fix.

**Processing:**
- If minor issues: auto-patch the plan inline (e.g., add a missing "run migration" step) and note what you corrected.
- If critical (nonexistent files, wrong approach): stop and report to the user for revision.
- If clean: proceed to Stage 2.

## Stage 2 — Implement

**Ground in the live code first.** Before writing anything, follow `skills/sdlc/templates/convention-grounding.md`: the existing code is the source of truth (not `AGENTS.md` / `CLAUDE.md` — read those as hints, verify against code, follow the code when they disagree). Find the 2–3 closest existing implementations and reuse their patterns (layout, naming, error handling, the data-access seam, shared utilities) instead of inventing parallel ones. If the plan has a `## Conventions & reuse` block, honor it and re-verify it against current code.

Stage 2 is **auto-gated** (no flag). Small / single-surface plans you implement in one pass; large multi-surface plans you implement **lane by lane in order**, then reconcile. You are always the implementation layer — there is no worker handoff — but the gate decides whether to split the work into focused lanes.

### Gate

From the parsed plan, compute:
- `surfaces_touched` = distinct surfaces the planned files match (frontend: `*.tsx/jsx/vue/svelte/css/scss`; backend: `*.py/go/rb/java/ts` in server dirs; data: `migrations/`, `schema/`, `models/`, `*.sql`; docs: `*.md`, `docs/`).
- `task_count` = number of implementation steps.
- `DECOMPOSE_MIN_TASKS` = `6` by default (override via `agents.decompose_min_tasks` in `.claude/project.json`).

**Decompose iff** `surfaces_touched >= 2` AND `task_count >= DECOMPOSE_MIN_TASKS` AND the per-surface file sets are disjoint (no file in two surfaces, not all in one). Otherwise implement single-pass. Note the decision and its inputs in your scope report — never decide silently.

### Single-pass (default)

Implement the plan steps yourself, in order:
- Follow the steps in order; use the exact file paths.
- Follow patterns from referenced existing files.
- Do NOT add features beyond the plan; do NOT skip steps.

### Decompose (large multi-surface plans) — sequential lanes

1. **Decompose.** Classify the planned files by surface into disjoint **lanes** (data / backend / frontend / docs). For each lane note its files, its steps, which lanes it depends on, and the **interface contract** — the shared types, endpoint shapes, and seams other lanes must honor. If you cannot make the lanes file-disjoint, fall back to single-pass.
2. **Implement each lane in dependency order** (default `data → backend → frontend`), one lane fully before the next. While in a lane, edit only that lane's files and code against the recorded contract — do not reach into another lane's files. Implementing downstream lanes against the fixed contract (instead of guessing) is what keeps the pieces consistent.
3. **Converge.** After all lanes are done, reconcile across them: wire up imports, call sites, and shared types; sweep the changed files for unresolved imports or colliding symbols; fix any seam mismatch where a lane diverged from its contract.

When decomposed, record the lane list and the gate decision in the run state (`stage2_decomposed`, `lanes`) and write `decompose.json` / one `implement-<lane>.json` per lane / `converge.json` instead of a single `implement.json`.

After implementation (either path):
- Run `git diff --stat` and confirm the expected files were created or modified.
- If you hit an error or blocker, STOP and report — don't paper over it.

## Stage 3 — Generate evals

Create test cases that verify the plan's INTENT, not just "does it compile."

**New Python pure functions** → `tests/eval/test_{feature_slug}_eval.py` with parameterized cases. Import via `tests/eval/conftest.py::load_script_module()` if that helper exists; otherwise import directly.

**New scripts with `--input` fixtures** → create:
- `<eval.features_dir>/{feature_slug}/fixtures/{scenario}.json` — input data.
- `<eval.features_dir>/{feature_slug}/expected/{scenario}.json` — expected output.

The runner discovers new features by scanning `<eval.features_dir>/*/` — no registration.

**No testable surface** (pure config change, doc-only) → note and proceed.

If no `eval.runner` is configured in `.claude/project.json`, skip Stages 3 and 4 (no eval surface to drive a fix loop) and proceed to Stage 5.

## Shared fix loop (Stages 5 / 5.5 / 5.6)

On a gate failure: parse the results, dispatch a fix for **only** those failures (no
refactor), re-run the gate. Max **3 iterations, shared across Stages 5/5.5/5.6**. On
exhaustion, pause with the Diagnosis block from `/sdlc` (fastest path `/triage <slug>`;
or name the class — flaky · code-defect · plan-wrong · config-missing — and one command),
then `--resume` reuses the green stages.

**Stage 4 was deleted.** It ran `eval.runner`, then Stage 5 ran the same command again as
its eval-regression layer — a strict prefix. Sharing this budget, its pause could halt a
run on self-authored evals before the real suite was ever consulted. Stage 3 still authors
the tests; Stage 5 runs them.

## Stage 5 — Run /test-check

Invoke `/test-check` to run the project's configured test suite and log audit. It reads `.claude/project.json` for commands and skips gracefully on missing keys.

- If green: proceed to Stage 5.6.
- If new failures (introduced by this change, not pre-existing): fix them and re-run. Same fix-loop budget.
- Pre-existing failures: note and skip — not your problem in this PR.

## Stage 5.6 — Flow simulation (/flowsim)

Run when a parent plan is available (i.e. you passed a plan file rather than a bare task row). Invoke `/flowsim {plan_file}`. Flowsim reads the plan, traces each claimed flow through the source, and writes a structured report to `plans/flowsim-{feature_slug}.json`.

- No mismatches: record "flowsim: all flows aligned" in the commit trailer and proceed to Stage 6.
- Mismatches: fix the code at each `file:line` anchor (or, if the plan was wrong, update the plan). Re-run `/flowsim`.
- Persistent mismatches past 3 fix-loop iterations: stop before PR and report. A human should adjudicate whether the plan or the implementation is wrong.

## Stage 5.7 — Adversarial review (inline, sequential)

**Opt-in, permanently — never runs by default.** Runs after Stage 5.6 flowsim, before Stage 6,
only when explicitly turned on this run (`--review-model <name>`, or an explicit
`pipeline.review_fix.enabled: true`; default reviewer `opus` once enabled — see
`skills/sdlc/templates/models.md`). An omitted `pipeline.review_fix` block, or
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

**Cap the fan-out with `agents.code_review_max_lenses`** (default `4`, inert until set): it
truncates the resolved list **in order** after circuit-breaker demotion, so `1` keeps
`correctness`. A non-integer or non-positive value falls through to `4` — never `0`, which would
silently disable the stage. Every lens runs at the **reviewer** model (`models.code_review`,
default `opus`), which `models.cap` does **not** govern; when a cap is set and the reviewer
outranks it, say so and point at `models.code_review` / `agents.code_review_max_lenses`.


**No parallel sub-agents on this runtime.** Run each **configured** lens
(`agents.code_review_lenses` in `.claude/project.json`; when the key is absent, all four
defaults below. Setting fewer cuts this stage's cost roughly linearly — it is one pass per
lens — so pick by what the diff risks; `correctness` is the highest-yield single lens. Print
the resolved list before starting.) The defaults: correctness,
plan⇌code alignment, config/env/docs consistency, security (checklists:
`skills/sdlc/templates/review-correctness-checklist.md`, `skills/sdlc/templates/review-security-checklist.md`) — as one sequential inline pass over the
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
`skills/sdlc/templates/models.md`). Per `pipeline.review_fix.mode` (default `interactive`):
- **`interactive`**: present each fix spec for approve / edit / skip. Approved specs run through
  the existing Stage 2/4 implement+fix machinery inline, then a fresh adversarial re-review of the
  touched files (this loop iteration's own pass) decides whether another iteration is needed. Loop
  until clean or `max_fix_loops` (own budget, separate from the shared fix budget).
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
numbered `review-fix-<n>.json` files. `/sdlc` treats a surviving HIGH-severity confirmed finding as
blocking Stage 6; stop and report rather than opening the PR.

## Stage 6 — Create PR

1. Create branch: `git checkout -b sdlc/{feature-slug}`.
2. Stage specific files (never `git add .`):
   ```
   git add <files touched during implementation>
   ```
3. Commit with a structured message:
   ```
   feat: {feature title from plan}

   Implemented via /sdlc pipeline from {plan_file}.

   Evals: {passed}/{total} passing
   Tests: {test-check summary}
   Flowsim: {all-aligned | mismatches resolved}
   ```
4. Push: `git push -u origin sdlc/{feature-slug}`.
5. Create PR via `gh pr create` with a body that includes: plan file link, eval results, test results, flowsim summary, files changed.
6. Trigger a code review pass over the diff. On Copilot, invoke `/review` if available; otherwise summarize the diff yourself in the chat (severity-tagged: blocker / nit / question). Skip if `pipeline.skip_review: true` in `.claude/project.json`. The review stays in chat — post it as a PR comment via the GitHub MCP only if the user asked for team-visible review.
7. **Capture at loop-exit** — run the shared protocol in `skills/gotcha/SKILL.md` ("Capture at loop-exit"). Auto-draft a gotcha entry **only** on an objective trigger — a fix-loop (eval/test/flowsim) that **failed-then-recovered**, or the user voicing surprise — route it through gotcha's dedup check, and ask a single confirm. A clean run stays silent (no vibe-gating). `/sdlc` commits the capture with the run; it does not use the `.next-action` seam.

8. **Leave re-entry rows** so the queue keeps the follow-up (a finished run seeds its own next step): always append `- [ ] (P2) verify PR #<n> of {feature-slug} merged & deployed — /post-deploy-verify plans/{feature-slug}.md`; when a manifest/lockfile/Dockerfile changed (deploy-delta), also `- [ ] (P1) rebuild <env> for {feature-slug} (dependency change — rebuild, not restart) — plans/{feature-slug}.md`. Also set `run.json.next_action = {"cmd": "/post-deploy-verify plans/{feature-slug}.md", "confirm": false}` (L8) so `/next` recovers the handoff after the sentinel fires.

Do NOT switch back to `main` after the PR — leave the branch checked out so the user can inspect.

## Stage 7 — Report

Summarize:
- PR URL
- Branch name
- Eval pass/fail counts
- Test-check summary
- Flowsim status
- Anything a human reviewer should know before merging

## Safety rules

- Never push to `main`.
- Never merge the PR yourself.
- Always stage specific files — no blanket `git add .`.
- Stop on ambiguity and report; don't guess at user intent mid-pipeline.
- Fix only NEW failures, not pre-existing ones.
- If any stage genuinely can't proceed (missing config, plan references nonexistent files, git conflict), stop and report — the user needs to resolve it.
