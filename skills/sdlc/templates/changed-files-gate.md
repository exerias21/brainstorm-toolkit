# Changed-files gate

A shared primitive for "did this change touch <surface>?" so stages don't each
re-derive it. Consumed by `/sdlc` Stage 5 (e2e/visual trigger) and Stage 5.5
(ui/data validator gating), and reusable by `/sdlc-lite`.

## Source of truth

Read the changed-file set from the run's `stage-outputs/implement.json`
`data.files_changed[].path` (already recorded). Fall back to
`git diff --name-only <base_commit>..HEAD` (or `--staged` for an uncommitted
working tree) only if the sidecar is absent.

## Canonical surface globs

Tunable per-repo via `.claude/project.json::discipline` (all optional; the
defaults below apply when a key is absent). A surface with no matching files
is simply inactive — **project-agnostic: a repo without a frontend never trips
the frontend gate.**

| Surface | Default globs | project.json key |
|---|---|---|
| frontend | `**/*.{tsx,jsx,vue,svelte,css,scss}`, `frontend/**/*.ts` | `discipline.frontend_globs` |
| backend  | `**/*.{py,go,rb,java,ts}` (server dirs) | `discipline.backend_globs` |
| data     | `**/migrations/**`, `**/schema/**`, `**/models/**`, `*.sql` | `discipline.data_globs` |
| docs     | `**/*.md`, `docs/**` | `discipline.docs_globs` |
| **deploy-delta** | `requirements.txt`, `pyproject.toml`, `poetry.lock`, `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `go.mod`, `Cargo.toml`, `Gemfile.lock`, `Dockerfile`, `**/Dockerfile` | `discipline.deploy_delta_globs` |

> **`.ts` is dual-surface.** `.ts` matches the backend glob everywhere; it ALSO
> matches frontend under a `frontend/` root, so `frontend/src/lib/util.ts` counts
> as BOTH surfaces and trips the frontend e2e/visual + `ui`-validator gate (a
> `.ts`-only frontend change must not silently skip those). A frontend-only TS
> repo that keeps sources at the repo root (no `frontend/` dir) should add
> `src/**/*.ts` (or its layout) to `discipline.frontend_globs`.

## Gate semantics

For each surface, compute `touched = any(changed_file matches a surface glob)`.
A consuming stage uses `touched` to decide whether its check is **required**:

- **frontend touched** → a visual/e2e check is expected before handoff/PR. If
  none ran, that's a soft-stop candidate (see `/sdlc` "Soft-stop tier"), not a
  silent pass.
- **data touched** → the migration-drift expectations apply (did the plan say
  to apply it? — Stage 1.5 completeness already asks; `/repo-health` Check 6
  catches drift later).
- **backend touched** → backend tests are expected in Stage 5.
- **deploy-delta touched** → a dependency manifest / lockfile / Dockerfile
  changed, which means **"code committed" ≠ "running environment reflects
  it."** The deployed app needs a **rebuild, not just a restart**. Emit a
  `⚙ rebuild required (not restart)` note in the PR body and the Stage-7 test
  checklist. (Containerized test runners with a baked test dir may also need
  new test files copied/rebuilt before they're visible — flag that too.) The
  pipeline validates the diff; this flags the deploy delta the diff implies.

The gate never blocks on its own; it converts "the user has to remember to
check the frontend / rebuild the image" into "the pipeline notices the
frontend changed (or a dep was added) and says so." Data-driven off the diff,
not the user's prompt.
