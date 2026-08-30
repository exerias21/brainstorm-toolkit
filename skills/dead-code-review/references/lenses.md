# Dead-code lenses — per-agent checklists

Loaded by `/dead-code-review` at Phase 2, once the surfaces are resolved. Each lens is one
agent. Surface names below are **roles, not paths**: resolve each to this repo's actual
directories from `.claude/project.json` `modules` (or, absent that, from the repo layout —
the language/package manifests tell you where the code lives). A repo with no such surface
skips that lens and says so.

Tiers are the *starting* tier for each lens. Resolve the real one per
`skills/sdlc/templates/models.md` (`--model <tier>` > `models.cap` > the tier here) and print
`model: <tier> (cap: <cap|none>)` before dispatching. The fan-out is Sonnet-first, so the
Opus-tier lens runs Sonnet unless the user opts up. Agents do **not** spawn sub-agents.

---

## Lens 1 — Server / backend code (Sonnet)

The compiled-or-interpreted service layer: API handlers, business logic, background jobs.

- Unused imports — check every import against usage in its own file
- Dead functions and methods — defined but never called; grep the name across the whole repo,
  not just the module
- Dead endpoints — routes with no client consumer; cross-reference the client's API layer
- Unused request/response models or DTOs — declared but never serialized either way
- Unused variables — assigned, never read
- Stale one-shot scripts — migration runners, seeders, one-time diagnostics that already ran
- Commented-out code blocks
- Redundant inline imports — the same module imported both at top level and inside a function

## Lens 2 — Client / frontend code (Sonnet)

The UI layer: components, views, client-side state, the API client.

- Unused components and views — grep the import name across all files
- Unused hooks / composables / directives
- Unused module exports — exported, never imported anywhere
- Unused type or interface declarations
- Dead client-state properties and actions — defined in the store, never read by a view
- Dead API-client methods — never called from any component, page, or hook
- Dead API types — never imported outside the file that declares them
- Unused package dependencies — grep for the package's import specifier across the tree
- Stale test files — tests for components that no longer exist

## Lens 3 — Data layer and migrations (Opus tier — Sonnet by default under the cap)

Highest blast radius: a wrong drop here can destroy production data, which is why the tier is
raised. **Never issue DDL** — this lens reports, it does not execute.

- Unused tables — present in the schema, never referenced from application code
- Unused columns — never selected, inserted, or updated
- Duplicate indexes — a plain index covering the same columns as a unique constraint
- Redundant migrations — a create later dropped, or an alter adding a column that already exists
- Duplicate migration numbers or out-of-order revisions
- Empty tables that suggest an abandoned feature

Report every finding with the evidence that made it look dead, and mark anything you could not
prove as `LOW` confidence. Reflection, string-built queries, and ORM lazy relations all hide
usage from grep.

## Lens 4 — Documentation and plans (Haiku)

Every `.md` outside vendor directories: docs, plans, and repo-root files.

- Completed plans and specs — the feature shipped; the plan is now history
- Stale root markdown — old debugging notes, one-time setup guides, superseded roadmaps
- Documentation that contradicts the repo's agent-instruction file (`AGENTS.md` / `CLAUDE.md`)
- Empty directories left behind by an earlier cleanup

Prefer moving a genuinely historical document to an archive directory with a dated header over
deleting it outright; delete only what is both stale and unreferenced.

## Lens 5 — Scripts, config, and test infrastructure (Haiku)

- One-shot scripts already run — seeders, data fixers, diagnostics
- Stale test files — tests for removed features, or driving navigation that no longer exists
- Orphaned config — build configs for a tool no longer used, saved auth state, dead CI jobs
- Stale dependency entries in the language's manifest
- Generated output directories that should be cleaned or gitignored

---

## Reporting contract (every lens)

Return findings grouped by confidence:

- **HIGH** — you traced every reference and found none. Include the search you ran.
- **MEDIUM** — looks dead, but the language allows invocation your search cannot see.
- **LOW** — suspicious only.

Each finding: the path, the symbol or block, why it looks dead, and what would break if you
were wrong. Research only — **no edits.** Removal happens at Phase 3, after triage.
