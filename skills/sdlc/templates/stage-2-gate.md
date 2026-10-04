# Stage 2 — the decompose gate (shared)

Canonical for `/sdlc`. Compute, then route: single implement agent
(the default) or a 2a/2b/2c decomposed fan-out.

## The gate (compute, then route)

Read `stage-outputs/parse.json`. Compute:
1. `surfaces_touched` = the distinct surfaces from `skills/sdlc/templates/changed-files-gate.md`
   (frontend / backend / data / docs / deploy-delta) that the **planned** files
   in `parse.json.data.files_to_change` match. The gate runs *before* any code
   exists, so apply the surface globs to intended files, not to a diff.
2. `task_count` = `parse.json.data.implementation_step_count`.
3. `DECOMPOSE_MIN_TASKS` — a named constant, **default `6`**, overridable via
   `.claude/project.json` `agents.decompose_min_tasks`.
4. `DECOMPOSE_MIN_FILES` — a named constant, **default `12`**, overridable via
   `.claude/project.json` `agents.decompose_min_files`, compared against
   `len(parse.json.data.files_to_change)`. Catches the shape `task_count` alone
   misses: a small step count spanning a large file count (observed live — 4
   steps across ~20 files routed to a single agent).
5. **Disjointness:** classify each planned file by surface; if any file matches
   more than one surface, or every file lands in a single surface, the surfaces
   are not cleanly separable.

**Decompose iff** `surfaces_touched.count >= 2` **AND** (`task_count >=
DECOMPOSE_MIN_TASKS` **OR** `len(files_to_change) >= DECOMPOSE_MIN_FILES`) **AND** the
per-surface file sets are disjoint. Otherwise → single-agent fallback. Record the decision
**and both inputs** (`task_count`, `len(files_to_change)`) so a reader sees exactly why it
did or didn't fan out (decompose path: `decompose.json`; single-agent path: the gate summary
in `implement.json`). Never a silent choice.

On Stage 2a entry set `run.json.data.stage2_decomposed` (bool) and
`run.json.data.lanes` (lane-name list, or `[]` when not decomposing).
