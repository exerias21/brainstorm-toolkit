---
name: dead-code-review
description: >
  Launches a parallel fan-out of review agents (tiered by load, Sonnet-first — capped per
  project.json models.cap / --model) to find dead code, dead docs, and dead plans, then removes
  them and runs the test suite before and after to verify zero regressions. THIS IS THE SKILL FOR
  "launch a few agents to review everything for dead code / anything no longer needed" — use it
  instead of hand-composing an ad-hoc agent fan-out. Scans whatever surfaces the repo actually has — server code,
  client code, data/migrations, documentation, scripts — for unused imports, dead functions,
  orphaned components, stale plans, and redundant migrations. Use when the user says /dead-code-review,
  "what can be deleted", "what's no longer needed", "what docs are worth keeping vs getting rid
  of", "clean this up", "look for dead code", or asks to sweep the repo after a feature lands, a
  refactor, or before a release.
argument-hint: "[scope] - optional: 'backend', 'frontend', 'database', 'docs', 'full' (default: full)"
metadata:
  brainstorm-toolkit-applies-to: claude copilot codex
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

Run the configured test suites (from `.claude/project.json` `test.*` — `unit`, `frontend`,
`e2e`) and record pass/fail counts. Skip any key that is not configured, and say which you
skipped. No `project.json` and no discoverable suite means **no baseline**: say so plainly and
restrict the run to report-only, because "zero regressions" is unverifiable without one.

### Phase 2: Launch Parallel Analysis Agents

Launch up to 6 agents in parallel. Each agent does **research only** — no edits — and reports back
findings with confidence levels. Models are tiered by reasoning load: Haiku for grep-heavy hygiene
work, Sonnet for code-pattern reasoning across one language, and an Opus tier for cross-module
dependency reasoning where wrong calls have high blast radius. **Model cap:** these are *defaults* —
resolve each per `skills/sdlc/templates/models.md` (`--model <tier>` > `project.json` `models.cap` >
the tier here). The fan-out is **Sonnet-first**, so the Opus tier runs Sonnet unless you opt up with
`--model opus`; print `model: <tier> (cap: <cap|none>)` before each dispatch. NO subagents.

**Read `skills/dead-code-review/references/lenses.md` now** — it carries the five lenses and
their per-surface checklists, plus the shared reporting contract.

First resolve which lenses apply. The surfaces are **roles, not paths**: read
`.claude/project.json` `modules` if present, otherwise infer them from the repo layout. A repo
with no client code skips the client lens; a repo with no database skips the data lens. Say which
lenses you dropped and why — a silent skip reads as "clean".

| Lens | Tier | Applies when |
|---|---|---|
| 1 — Server / backend code | Sonnet | there is a service or library layer |
| 2 — Client / frontend code | Sonnet | there is a UI surface |
| 3 — Data layer and migrations | Opus tier | there is a schema or migration directory |
| 4 — Documentation and plans | Haiku | always |
| 5 — Scripts, config, test infra | Haiku | always |

Dispatch the applicable lenses in one message. There is no separate test-runner agent — Phase 1
already established the baseline.

### Phase 3: Consolidate & Execute

After all agents report back:

1. **Triage findings** by confidence level (HIGH/MEDIUM/LOW)
2. **Execute HIGH-confidence removals first** — deletions, import cleanups, dead function removal
3. **Restart or rebuild** the running stack if the repo has one (`project.json` `stack.*`)
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
| `full` (default) | every lens that applies to this repo |
| `backend` | lenses 1 + 3 |
| `frontend` | lens 2 |
| `database` | lens 3 |
| `docs` | lenses 4 + 5 |

## Rules

- Use the tiered assignments in `references/lenses.md` (Haiku / Sonnet / Opus) — do NOT promote everything to Opus.
  The fan-out is **Sonnet-first**, so the Opus tier is an explicit opt-up (`--model opus`); each agent's
  tier is chosen based on reasoning load and blast radius of a wrong
  call. If a specific run genuinely needs deeper analysis (e.g., the database agent flags ambiguous
  cross-module references), promote that single agent — not the whole fleet.
- Agents do NOT use subagents — each does all its own work
- Never commit during the review — the user decides when to commit
- Always run tests before AND after to verify zero regressions
- Only remove code at HIGH confidence unless the user explicitly approves MEDIUM items
- Consult `GOTCHAS.md` at repo root (or `project.json` `gotchas_file`) for known patterns
- If a function appears unused but is referenced by a string-based dispatch (like intent routing), do NOT remove it
- If a type is used as a return type of a live API method, do NOT remove it even if never imported externally
