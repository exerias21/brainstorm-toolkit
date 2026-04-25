---
name: dead-code-review
description: >
  Comprehensive dead code detection and removal. Launches parallel review agents (Opus 4.6) to scan
  backend Python, frontend TypeScript, database/migrations, documentation, and scripts for unused
  imports, dead functions, orphaned components, stale plans, redundant migrations, and more. Also runs
  test suite before and after to verify zero regressions. Invoke with /dead-code-review or trigger
  proactively after major feature completions, refactors, or before releases.
argument-hint: "[scope] - optional: 'backend', 'frontend', 'database', 'docs', 'full' (default: full)"
metadata:
  brainstorm-toolkit-applies-to: claude copilot
---

# Dead Code Review

Systematically find and remove dead code, stale documentation, unused database objects, and orphaned
files across the entire codebase. Uses parallel agents tiered by reasoning load (Haiku / Sonnet / Opus)
for exhaustive analysis, then applies fixes with test verification.

## When to trigger this skill

- User invokes `/dead-code-review`
- After completing a major feature or multi-file refactor
- Before a release or milestone
- When the user asks to "clean up", "remove dead code", or "audit the codebase"
- Periodically (monthly) as codebase hygiene

## Process

### Phase 1: Establish Test Baseline

Run all three test suites and record pass/fail counts:
- Backend: `docker compose exec -T backend python -m pytest tests/ -v --tb=short`
- Frontend: `cd frontend && npx vitest run`
- E2E: `npx playwright test tests/e2e/ --reporter=list`

### Phase 2: Launch Parallel Analysis Agents

Launch up to 6 agents in parallel. Each agent does **research only** — no edits — and reports back
findings with confidence levels. Models are tiered by reasoning load: Haiku for grep-heavy hygiene
work, Sonnet for code-pattern reasoning across one language, Opus only for cross-module dependency
reasoning where wrong calls have high blast radius. NO subagents.

#### Agent 1: Backend Python Reviewer (Sonnet)
Scans ALL files in `backend/` for:
- Unused imports (check every import against usage in the file)
- Dead functions (defined but never called — grep for function name across entire project)
- Dead API endpoints (backend routes with no frontend consumer — cross-reference with `frontend/src/lib/api.ts`)
- Unused schema classes (Pydantic models never used in requests/responses)
- Unused variables (assigned but never read)
- Stale one-time scripts (`run_migration_*.py`, `seed_*.py`, `backend/scripts/check_*.py`)
- Commented-out code blocks
- Redundant inline imports (same module imported at top and inline)

#### Agent 2: Frontend TypeScript Reviewer (Sonnet)
Scans ALL files in `frontend/src/` for:
- Unused components (grep for component import name across all files)
- Unused hooks (grep for hook name across all files)
- Unused lib exports (grep for export name across all files)
- Unused type definitions (grep for type name across all files)
- Dead store properties/actions (defined in Zustand store but never accessed from components)
- Dead API methods in `lib/api.ts` (methods never called from any component/page/hook)
- Dead API types in `lib/api.ts` (types never imported outside the file)
- Unused dependencies in `package.json` (grep for package import across all files)
- Stale test files testing deleted components

#### Agent 3: Database & Migration Reviewer (Opus)
Cross-module dependency reasoning: a wrong drop here can break production. Opus warranted.
Scans ALL files in `backend/migrations/` and queries the live database:
- Unused tables (exist in DB but never referenced in Python code)
- Unused columns (defined but never SELECT'd/INSERT'd/UPDATE'd)
- Duplicate indexes (regular index on same columns as a UNIQUE constraint)
- Redundant migrations (CREATE then later DROP, or ALTER adding columns that already exist)
- Duplicate migration numbers
- Empty tables that may indicate abandoned features

#### Agent 4: Documentation & Plans Reviewer (Haiku)
Scans ALL `.md` files in `docs/`, `plans/`, and project root:
- Completed plans/specs (feature fully implemented — delete the plan)
- Stale root markdown files (old debugging notes, one-time setup guides)
- Outdated documentation that conflicts with CLAUDE.md
- Empty directories left after prior cleanup

#### Agent 5: Scripts & Config Reviewer (Haiku)
Scans `scripts/`, config files, test infrastructure:
- One-time scripts already run (data seeders, migration fixers, diagnostics)
- Stale test files (tests for removed features, tests using old navigation patterns)
- Orphaned config files (unused Vite configs, stale auth state files)
- Stale dependencies in `requirements.txt` or `package.json`
- Generated output directories that should be cleaned

#### Agent 6: Test Runner (Baseline — Haiku)
Runs the full test suite to establish what's currently passing before any changes. No reasoning load
— just runs commands and reports pass/fail counts.

### Phase 3: Consolidate & Execute

After all agents report back:

1. **Triage findings** by confidence level (HIGH/MEDIUM/LOW)
2. **Execute HIGH-confidence removals first** — deletions, import cleanups, dead function removal
3. **Restart services** after backend/frontend changes
4. **Re-run test suite** to verify zero regressions
5. **Execute MEDIUM-confidence removals** if tests pass
6. **Final test run** to confirm everything

### Phase 4: Report

Provide a summary table:
- Files deleted (count + line count)
- Files modified (count + lines removed)
- Database objects dropped (tables, indexes, columns)
- Test comparison (baseline vs after cleanup)

## Scope Options

| Scope | What runs |
|-------|-----------|
| `full` (default) | All 6 agents |
| `backend` | Agent 1 (Python) + Agent 3 (Database) + Agent 6 (Tests) |
| `frontend` | Agent 2 (TypeScript) + Agent 6 (Tests) |
| `database` | Agent 3 (Database) only |
| `docs` | Agent 4 (Documentation) + Agent 5 (Scripts) |

## Rules

- Use the tiered model assignments above (Haiku / Sonnet / Opus) — do NOT promote everything to Opus
  by default. The tier is chosen for each agent based on reasoning load and blast radius of a wrong
  call. If a specific run genuinely needs deeper analysis (e.g., the database agent flags ambiguous
  cross-module references), promote that single agent — not the whole fleet.
- Agents do NOT use subagents — each does all its own work
- Never commit during the review — the user decides when to commit
- Always run tests before AND after to verify zero regressions
- Only remove code at HIGH confidence unless the user explicitly approves MEDIUM items
- Consult `.claude/skills/gotcha/GOTCHAS.md` Code Hygiene section for known patterns
- If a function appears unused but is referenced by a string-based dispatch (like intent routing), do NOT remove it
- If a type is used as a return type of a live API method, do NOT remove it even if never imported externally
