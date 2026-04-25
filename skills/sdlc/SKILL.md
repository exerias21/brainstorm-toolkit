---
name: sdlc
description: >
  Automated plan-to-PR pipeline. Takes a plan file, implements it via agent,
  generates evals, runs eval+fix loop, validates with /test-check, and creates
  a PR for human review. The full SDLC lifecycle minus human merge.
argument-hint: "{plan_file} [--dry-run] [--skip-eval] [--skip-flowsim] [--max-fix-loops N] [--background]"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# SDLC Pipeline

Autonomous feature delivery: plan file in, PR out.

```
/brainstorm → plan → /sdlc → sanity-check → implement → eval → fix → validate → flowsim → PR → human review
```

## Arguments

- `plan_file` (required): Path to the plan (e.g., `plans/my-feature.md`)
- `--dry-run`: Parse plan and report what would be done, without implementing
- `--skip-eval`: Skip eval generation and fix loop (Stages 3-4) and skip flowsim
- `--skip-flowsim`: Skip Stage 5.6 flow simulation only (evals still run)
- `--max-fix-loops N`: Max eval-fix iterations (default: 3)
- `--background`: Run as background agent, notify when PR is ready

## Prerequisites

- Plan file must exist and contain implementation steps
- Git working tree must be clean (no uncommitted changes)
- `.claude/project.json` exists with at least `main_branch`; `test.*`, `logs.*`,
  and `eval.*` are recommended so Stages 4-5 work. Missing config just causes
  those stages to skip, not fail.

---

## Stage 1: Parse Plan

Read the plan file and extract structured information:

1. **Read** the plan file fully. The plan source can be:
   - A standard brainstorm plan (e.g., `plans/brainstorm-<slug>.md` with Direction / Implementation Steps / Acceptance Criteria sections), OR
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

If `--dry-run`, stop here and report.

---

## Stage 1.5: Plan Sanity Check

Before spending Opus tokens on implementation, verify the plan is actually
correct. Launch 3 Haiku agents **in parallel** (single message) to check
different dimensions. This is cheap insurance — catches wrong file paths,
missing steps, and known gotchas before they become bugs.

```
# Launch all 3 in a single message:

Agent(
  model="haiku",
  description="Verify plan file paths and patterns for {feature_name}",
  prompt="""
    Read the plan at {plan_file}. For every file path mentioned:
    1. Verify the file exists (use Glob or ls)
    2. If the plan references a specific function, class, symbol, or
       import path, grep for it in the actual file to confirm it's valid
    3. If the plan says "follow the pattern in X", read X and verify
       the plan's description matches what's actually there

    Report a JSON array:
    [{path: "file.py", exists: true/false, issues: ["description"]}]
  """
)

Agent(
  model="haiku",
  description="Check plan completeness for {feature_name}",
  prompt="""
    Read the plan at {plan_file}. Check for common missing-step categories:
    1. Creates a DB migration → does the plan mention running/applying it?
    2. Creates a new API endpoint → does the plan mention registering it
       with the router / app (whatever pattern this project uses)?
    3. Creates a new frontend component → does the plan mention importing
       it in the parent page/layout?
    4. Adds a new config key or environment variable → is it documented in
       the project's config files or example env?
    5. Adds a new database table → does the plan mention indexes?
    6. Adds a new background job or scheduled task → does the plan mention
       registering it with the scheduler?

    Infer the project's patterns from its README, CLAUDE.md, and existing
    code before flagging. A check only fails if the project would actually
    need that step.

    Report: [{check: "description", status: "pass/fail", detail: "..."}]
  """
)

Agent(
  model="haiku",
  description="Scan plan for known gotchas in {feature_name}",
  prompt="""
    Read the plan at {plan_file}.

    Then read the project's gotchas file — path is `gotchas_file` in
    `.claude/project.json` (default `GOTCHAS.md` at repo root). If the
    file does not exist, report: {status: "no-gotchas-file"} and exit.

    Cross-reference each step in the plan against every gotcha in
    GOTCHAS.md. For each plan step, flag if any gotcha applies.

    Report: [{step: "N", gotcha: "title from GOTCHAS.md", suggestion: "fix"}]
  """
)
```

### Processing results

1. Collect all 3 agent reports
2. **If issues found**: auto-patch the plan file with corrections. Log a short
   summary of what was fixed, then proceed to Stage 2 with the corrected plan.
3. **If critical issues** (plan references nonexistent files, entire approach
   is misguided): report to user and **STOP** — the plan needs human revision.
4. **If all clean**: proceed to Stage 2.

---

## Stage 2: Implement

Spawn an implementation agent to execute the plan. Always use Opus 4.6 for
implementation — it handles complex multi-file changes more reliably.

```
Agent(
  model="opus",
  description="Implement {feature_name}",
  prompt="""
    Implement the following plan. Follow the steps exactly.
    Use existing codebase patterns and conventions.

    PLAN:
    {plan_content}

    CRITICAL RULES:
    - Follow the implementation steps in order
    - Use the exact file paths specified in the plan
    - Follow patterns from referenced existing files
    - Do NOT add features beyond what the plan specifies
    - Do NOT skip steps or take shortcuts
    - After implementation, run: git diff --stat to summarize changes
  """
)
```

After the agent completes:
1. Review the git diff summary
2. Verify the expected files were created/modified
3. If the agent reports errors or blockers, **STOP** and report to user

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

### For features without testable pure functions:

1. Create schema validation tests — does the output match the expected JSON structure?
2. Create smoke tests — does the script/endpoint return a valid response?
3. If no tests are possible, note "eval generation skipped — no testable surface" and proceed

### Key principle:

Evals must be created BEFORE running them. This is test-driven: define what
"correct" looks like first, then verify the implementation matches.

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
3. Spawn a fix agent (Opus for complex fixes, Sonnet for targeted fixes):

```
Agent(
  model="opus",
  description="Fix eval failures for {feature_name}",
  prompt="""
    Fix the following test failures. Each failure includes the test name,
    expected vs actual output, and the file/function to fix.

    Fix ONLY the specific issues identified. Do not refactor surrounding code.
    After fixing, the tests will be re-run to verify.

    EVAL RESULTS:
    {results_json}

    FILES TO EXAMINE:
    {file_paths from failures}
  """
)
```

4. After fix agent completes, re-run evals
5. Repeat up to `--max-fix-loops` iterations (default: 3)
6. If still failing after max iterations:

```markdown
## SDLC Pipeline — PAUSED

Eval failures persist after {N} fix attempts.
Remaining failures:
{failures_summary}

Please review and fix manually, then re-run:
  /sdlc {plan_file} --skip-eval
```

---

## Stage 5: Full Validation

Run the complete test suite to ensure no regressions.

1. Run `/test-check` via the test-check skill procedure, BUT with one substitution:
   - Log audit (if `logs.command` configured)
   - Frontend unit tests (if `test.frontend` configured and frontend files changed)
   - Backend unit tests (if `test.unit` configured and backend files changed)
   - **E2E tests — dispatch the `e2e-test-runner` agent** (if `test.e2e` configured and
     UI flow changed). The agent runs a fix loop for e2e failures with a flaky-test
     guard; its iterations count toward `--max-fix-loops`. If `test.e2e` is not
     configured, skip the e2e step entirely.
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

---

## Stage 5.5: Plan Requirements Validation

Re-read the plan file and validate that the implementation actually fulfills every
requirement. This catches "code works but feature is incomplete" — the gap between
passing tests and a working product.

**Skip this stage if `--skip-eval` was passed.**

### Launch validation agents in parallel

Spawn up to 4 agents in a **single message** (parallel launch). Each agent gets the
plan file path and a specific validation focus. Use the `ux-plan-validator` agent
definition (`.claude/agents/ux-plan-validator.md`) as reference for agent behavior.

```
# Launch all in a single message for parallel execution:

Agent(
  model="sonnet",
  description="Validate API requirements for {feature_name}",
  prompt="""
    You are a UX Plan Validator with focus="api".
    Read the agent definition at .claude/agents/ux-plan-validator.md for full instructions.

    Plan file: {plan_file}
    Feature: {feature_slug}

    Validate that every API endpoint specified in the plan exists, returns the
    correct status code, and has the expected response shape. Use the project's
    configured auth flow — check README.md / CLAUDE.md / .claude/project.json
    for test credentials or auth instructions.

    Return a structured pass/fail report per endpoint.
  """
)

Agent(
  model="sonnet",
  description="Validate UI requirements for {feature_name}",
  prompt="""
    You are a UX Plan Validator with focus="ui".
    Read the agent definition at .claude/agents/ux-plan-validator.md for full instructions.

    Plan file: {plan_file}
    Feature: {feature_slug}

    Validate that every frontend component and page specified in the plan
    renders correctly. If the project has a configured UI audit tool, use it.
    Otherwise, inspect components via direct file reads.

    Return a structured pass/fail report per component/page.
  """
)

Agent(
  model="haiku",
  description="Validate DB schema for {feature_name}",
  prompt="""
    You are a UX Plan Validator with focus="data".
    Read the agent definition at .claude/agents/ux-plan-validator.md for full instructions.

    Plan file: {plan_file}
    Feature: {feature_slug}

    Validate that all database tables, columns, and indexes specified in the
    plan exist. Read the project's DB connection helper (check CLAUDE.md or
    the project's conventions for how to connect) and query accordingly.

    Return a structured pass/fail report per table/column.
  """
)

Agent(
  model="haiku",
  description="Validate cross-module integration for {feature_name}",
  prompt="""
    Read the plan file: {plan_file}
    Feature: {feature_slug}

    Check the "Cross-Module Touchpoints" section of the plan.
    For each touchpoint mentioned, verify:
    - If it references a registration (e.g., a router, service, or allow-list
      name), grep for it
    - If it references an AI/assistant flow or recognized intent, check that
      it is registered
    - If it references a frontend page layout change, verify the component import

    Return a structured pass/fail report per touchpoint.
  """
)
```

### Process results

1. Collect results from all agents
2. Merge into a single validation report
3. **If all checks pass**: proceed to Stage 5.6
4. **If failures found**:
   - Feed the failure list back into the Stage 4 fix loop
   - The fix agent receives the validation report, not eval output
   - Re-run validation after fixes (counts toward `--max-fix-loops`)
5. **If failures persist after max iterations**: report to user and stop

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

---

## Stage 5.6: Flow Simulation (plan vs. implementation)

After Stage 5.5's checklist validation passes, run **`/flowsim`** as a narrative
cross-check: trace each claimed flow through the actual source and flag MISMATCH,
UNCLEAR, or MISSING steps. This catches the class of gap where every individual
checklist item passes but the end-to-end flow silently deviates from the plan's
intent (wrong ordering, skipped step, different module doing the work).

**Skip this stage if `--skip-flowsim` or `--skip-eval` was passed.**

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
   - Re-run `/flowsim` after fixes (counts toward `--max-fix-loops`).
5. **If mismatches persist after max iterations**:
   - Report to user with the specific file:line anchors that keep failing.
   - Do NOT proceed to PR — the plan and implementation disagree and a human should adjudicate (sometimes the plan was wrong, not the code).

### When to trust vs. question the flowsim output

- **A MISMATCH with a concrete `file:line` anchor** is high-signal: the code at that location actually differs from the plan. Fix or update the plan.
- **A MISSING marker** means flowsim couldn't find the claimed code at all. Could mean: not implemented, implemented elsewhere with a different name, or the plan was aspirational. Worth a human look.
- **An UNCLEAR** means the plan's language was too fuzzy to trace. Usually indicates a plan quality issue, not a code issue — re-run after clarifying the plan.
- **Corroborating eval evidence** (a passing or failing eval aligned with a flow step) is your highest-confidence signal; prioritize fixing those first.

---

## Stage 6: Create PR

Create a pull request for human review.

1. **Create branch**: `sdlc/{feature-slug}`
   ```bash
   git checkout -b sdlc/{feature-slug}
   ```

2. **Stage and commit** all changes:
   ```bash
   git add {specific files from the implementation}
   git commit -m "feat: {feature description from plan title}

   Implemented via /sdlc pipeline from {plan_file}.

   Changes:
   {git diff --stat summary}

   Eval results: {passed}/{total} tests passed
   Test-check: {pass/fail summary}

   Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
   ```

3. **Push and create PR**:
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

   Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
   EOF
   )"
   ```

4. **Report** the PR URL to the user

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

## When This Skill Works Best

- Bounded, well-specified plans with clear file paths and acceptance criteria
- Script creation, API endpoints, CRUD operations, refactors
- Any plan file with concrete steps and verifiable outcomes

## When to Skip or Use Cautiously

- UI/UX design work — human judgment needed for "feel"
- LLM prompt tuning — evals can't capture personality/tone reliably
- Cross-module features with ambiguous tradeoffs — brainstorm more first
