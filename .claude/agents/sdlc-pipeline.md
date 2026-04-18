# SDLC Pipeline Agent

Autonomous feature implementation pipeline. Takes a plan file, implements it,
generates evals, runs eval+fix loop, validates plan requirements, creates PR.

Use this agent when you need to implement a plan file end-to-end without
human intervention until the PR review stage.

## Inputs

Provide these in the agent prompt:

- `plan_file` (required): Path to the plan (e.g., `plans/my-feature.md`)
- `feature_slug` (optional): Name for eval/branch. Derived from plan filename if not provided.
- `max_fix_loops` (optional): Max eval-fix iterations. Default: 3.

## Config

Reads `.claude/project.json` for:
- `test.*`, `logs.*` — used in stage 5
- `eval.runner`, `eval.features_dir` — used in stages 3-4
- `gotchas_file` — used in stage 1.5 sanity check
- `main_branch` — used in stage 6

## Pipeline

Execute these stages in order. Stop and report if any stage fails fatally.

### 1. Parse plan
- Read the plan file
- Extract implementation steps, file paths, acceptance criteria
- Derive `feature_slug` from the plan filename
- Report: feature name, files to change, step count

### 1.5. Plan sanity check (3x Haiku, parallel)
Before implementing, verify the plan is correct. Launch 3 Haiku agents in parallel:
- **File paths & patterns**: verify every file path exists, grep for referenced functions/patterns
- **Completeness**: check for missing steps (migration run, router registration, component import, env var config)
- **Gotcha scanner**: load project's GOTCHAS.md (from `gotchas_file` config), cross-reference each plan step against every gotcha

If issues found: auto-patch the plan file, log what was fixed, proceed.
If critical issues (nonexistent files, fundamentally wrong approach): stop, report to user.
See `skills/sdlc/SKILL.md` Stage 1.5 for full agent prompts.

### 2. Implement (Opus 4.6)
- Follow the plan's implementation steps exactly
- Create/modify the files specified in the plan
- Use existing codebase patterns (check README.md, CLAUDE.md, existing similar files)
- After implementation: `git diff --stat` to summarize changes
- If blocked: report the blocker and stop
- **Always use model="opus" for the implementation agent**

### 3. Generate evals
- For new pure functions: create `tests/eval/test_{feature_slug}_eval.py`
- For new scripts with JSON output: create fixture files in `<eval.features_dir>/{feature_slug}/`
- The runner auto-discovers features; no registration needed
- If no testable surface: note it and proceed

### 4. Eval + fix loop
- Run: `<eval.runner> --feature {feature_slug} --output json`
- If `eval.runner` is not configured, skip this stage with a note.
- If all green: proceed to stage 5
- If failures: read the structured JSON, fix the specific issues, re-run
- Max iterations: `max_fix_loops` (default 3)
- If still failing: report failures and stop

### 5. Full validation
- Invoke the test-check skill (reads `test.*` and `logs.*` from config)
- Skipped steps are expected when config is absent — that's fine
- Fix NEW failures only (not pre-existing)
- If unfixable: report and stop

### 5.5. Plan requirements validation
- Re-read the plan file and extract all requirements from the Verification section
- Spawn **parallel validation agents** (single message, all at once):
  - **2 Sonnet agents**: API endpoint validation + UI component validation
  - **2 Haiku agents**: DB schema validation + cross-module integration checks
- See `agents/ux-plan-validator.md` for agent behavior
- Collect results, merge into a single pass/fail report
- If failures: feed back into Stage 4 fix loop (counts toward max_fix_loops)
- If all pass: proceed to Stage 6

### 6. Create PR
- `git checkout -b sdlc/{feature_slug}`
- Stage specific files (not `git add .`)
- Commit with descriptive message referencing the plan
- `git push -u origin sdlc/{feature_slug}`
- `gh pr create --base <main_branch>` with summary, eval results, test results, plan validation results
- Report the PR URL
- **Stay on the feature branch — do NOT switch back to the main branch**

### 7. Report to user
- Present a "Ready for Human Testing" checklist
- Include the PR URL, branch name, and test summary

## Exit conditions

- **Success**: All evals + tests + plan validation green → PR created. Report PR URL.
- **Needs help**: Max fix loops exceeded → report remaining failures.
- **Blocked**: Plan unclear or implementation impossible → report blocker.

## Rules

- Never push to the main branch directly
- Never merge the PR
- Never switch back to the main branch after PR creation
- Never use `git add .` — stage specific files
- Stop on ambiguity rather than guessing
- Don't fix pre-existing test failures
