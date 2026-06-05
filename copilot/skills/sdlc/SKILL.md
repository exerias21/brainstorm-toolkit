---
name: sdlc
description: >
  Sequential plan-to-PR pipeline for Copilot. Takes a plan file, implements it,
  generates and runs evals, validates with /test-check, and creates a PR for
  human review. This is a Copilot-adapted version of the full SDLC skill —
  runs the same stages, but inline and sequentially (no parallel worker spawning).
  Use when you have a finalized plan in plans/ or TASKS.md and want the pipeline
  to drive the delivery.
argument-hint: "{plan_file}"
metadata:
  brainstorm-toolkit-applies-to: copilot
disable-model-invocation: true
---

# SDLC Pipeline (Copilot Edition — Sequential)

Sequential version of the SDLC pipeline. Unlike the Claude Code canonical (which spawns Haiku/Opus/Sonnet workers in parallel), this overlay executes every stage inline: Copilot does the work itself, one stage at a time.

When Copilot's VS Code agent mode gains parallel worker support (Copilot CLI already has `/fleet`), this overlay can be upgraded. Today it ships as a useful degraded version — slower but complete.

## Prerequisites

- Plan file exists at the path you passed, OR you are pointing at TASKS.md.
- Git working tree is clean.
- `.claude/project.json` exists with at least `main_branch`; `test.*`, `logs.*`, and `eval.*` recommended so Stages 4–5 work.

## Stage 1 — Parse the plan

Read the plan file fully. Valid sources:
- `plans/brainstorm-<slug>.md` with Direction / Implementation Steps / Acceptance Criteria.
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

Before committing time to implementation, run three checks yourself — one pass for each:

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
- `DECOMPOSE_MIN_TASKS` = `6` by default (override via `pipeline.decompose_min_tasks` in `.claude/project.json`).

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

## Stage 4 — Eval + sequential fix loop

Run the configured eval runner:
```
<eval.runner> --feature {feature_slug} --output json
```

Parse JSON results.
- If all pass: proceed to Stage 5.
- If failures: fix them yourself inline — one failure at a time, or batched by file, whatever is clearer. Re-run the eval after each batch. Count each pass as one fix loop.
- If you've burned 3 fix-loop iterations and failures remain: report, pause, and ask the user to fix manually then re-run `/sdlc {plan_file}`.

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
