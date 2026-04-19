---
name: dead-code-review
description: >
  Sequential dead-code review for Copilot. Walk through six focused review phases
  (backend, frontend, database, docs, scripts, tests) inline, then triage findings
  and remove high-confidence items with test verification. Use /dead-code-review
  after a major feature, before a release, or when asked to "clean up" the repo.
  Copilot-adapted version of the canonical — sequential instead of parallel.
argument-hint: "[scope] - optional: 'backend', 'frontend', 'database', 'docs', 'full' (default: full)"
metadata:
  brainstorm-toolkit-applies-to: copilot
disable-model-invocation: true
---

# Dead Code Review (Copilot Edition — Sequential)

Six review phases done in order. Unlike the Claude canonical (which spawns six parallel Opus workers), this version walks them yourself, one at a time. Slower but complete.

## When to invoke

- User invokes `/dead-code-review`.
- After a major feature or multi-file refactor.
- Before a release or milestone.
- When asked to "clean up", "remove dead code", or "audit the codebase".

## Scope flag

| Scope | Phases run |
|---|---|
| `full` (default) | All 6 |
| `backend` | 1, 3, 6 |
| `frontend` | 2, 6 |
| `database` | 3 |
| `docs` | 4, 5 |

## Phase 0 — Test baseline

Run the configured test suites (from `.claude/project.json` `test.*` keys) and record pass/fail counts. This is the baseline — any removal must keep these counts intact.

## Phase 1 — Backend

Scan backend files for:
- Unused imports (grep each import against file usage).
- Dead functions (defined but not called anywhere in the repo).
- Dead API endpoints (routes with no frontend or external consumer).
- Unused schema classes (models / DTOs / Pydantic models never referenced).
- Stale one-time scripts (`run_*.py`, `seed_*.py`, diagnostic scripts already run).
- Commented-out code blocks older than current work.

## Phase 2 — Frontend

Scan frontend source for:
- Unused components (grep import name across all files).
- Unused hooks / lib exports / type definitions.
- Dead store properties or actions.
- Dead API methods or types in the API client module.
- Unused dependencies in `package.json`.
- Stale test files for removed components.

## Phase 3 — Database & migrations

Scan migration files and query live schema if available:
- Unused tables (exist in DB but never referenced in code).
- Unused columns (never SELECTed / INSERTed / UPDATEd).
- Duplicate indexes (regular index on same columns as a UNIQUE constraint).
- Redundant migrations (CREATE then DROP pairs; ALTER adding columns that already exist).
- Empty tables that may indicate abandoned features.

## Phase 4 — Docs & plans

Scan markdown files in `docs/`, `plans/`, and root:
- Completed plans (feature fully shipped → delete).
- Stale root markdown (one-time setup guides, old debugging notes).
- Outdated docs that conflict with current CLAUDE.md / AGENTS.md.
- Empty directories left from prior cleanup.

## Phase 5 — Scripts & config

- One-time scripts already run (data seeders, migration fixers, diagnostic checks).
- Stale test files for removed features.
- Orphaned config files (unused build configs, old auth state).
- Generated output directories that should be gitignored.

## Triage & execute

For each finding, assign confidence:
- **HIGH** — demonstrably unused (grep confirms zero references). Remove.
- **MEDIUM** — likely unused but harder to prove (string-dispatch, reflection). Leave for user approval.
- **LOW** — flagged as "looks suspicious" but uncertain. Report only; don't remove.

Execute HIGH-confidence removals first. Restart services if backend changed. Re-run the test suite — if green, execute MEDIUM items that the user explicitly approves. Final test run to confirm.

## Report

- Files deleted (count + total lines).
- Files modified (count + lines removed).
- Database objects dropped (tables / columns / indexes).
- Test comparison: baseline vs post-cleanup.

## Rules

- Never commit during the review — the user decides when.
- Always baseline and re-run tests around the changes.
- Only remove at HIGH confidence unless the user explicitly approves MEDIUM items.
- Check `GOTCHAS.md` Code Hygiene section for known-safe patterns.
- Do not remove functions that look unused but are referenced by string-based dispatch (intent routing, plugin registries).
- Do not remove a type that is the return type of a live API method, even if never imported externally.
