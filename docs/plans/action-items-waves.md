## Brainstorm Result: ACTION_ITEMS.md — what runs when

> Written 2026-10-02. Decided with the owner, question by question: TASKS.md stays the only
> source of truth; ACTION_ITEMS.md is **generated, never hand-edited**; it shows the **now**
> wave and the **next** wave; the human and `/sdlc --queue` both read it; the human launches
> parallel sessions (ideally one git worktree each), the toolkit never runs them concurrently;
> an empty now-wave **parks and reports**, it never falls back to plain priority order.

### Direction

Conventional approach **A — Stage 6 add-on**, with three wildcard grafts. A new deterministic
`close-tasks.sh waves` subcommand groups the open `TASKS.md` rows into a **now** wave and a
**next** wave, laid out **by lane** (the *Expo Rail* graft: lanes are the file's organizing
axis, and a lane holds one active row at a time). Grouping is **parallel-by-default** (the
*Inversion* graft): an untagged row is ready unless a known ordering or conflict says
otherwise, so today's untagged backlog still gets real parallelism. Ordering and conflicts
come from deterministic inference (within a plan, phase N+1 waits on phase N; two rows whose
plan phases name the same file conflict) plus explicit row tags, which win. A read-only
**worktree overlap warning** (the *Worktree Oracle* graft) flags a ready row whose files are
dirty in another git worktree right now. `/sdlc` Stage 6 regenerates `ACTION_ITEMS.md` right
after it closes its rows, and `--queue` selects from the now wave. An **opt-in reassess**
step (the owner's hybrid of inference + agent) proposes `_after:` / `_lane:` / `_conflicts:`
tags the rules cannot see; code validates and writes them, so the generator stays
reproducible. Its first implementation is a Sonnet agent; the Jev `depends-on` /
`classify-lane` / `conflicts` judge verbs replace it later, shadow-first. **Not a new skill**:
the always-resident description budget (≈7,000 of 7,500 characters) cannot absorb one, and
every piece hangs off code `/sdlc` already runs.

### Conventions & reuse

- Follow: `close-tasks.sh`'s subcommand shape — a bash dispatcher over one embedded Python
  body, JSON on stdout, read-only unless a `--write`/`--apply` flag says otherwise — see
  `do_board` (`scripts/close-tasks.sh`, `def do_board`) and the `rows)`/`board)` dispatch.
- Reuse: `parse_row` / `trailer` / `parse_sections` in `scripts/close-tasks.sh` for row tags
  and sections; `plan_row_key_match` for `_plan:` matching; `token_hit` for whole-token
  matching (never a bare substring — the reconcile over-close bug came from exactly that).
- Reuse: the surface **glob patterns** in `skills/sdlc/templates/changed-files-gate.md` and
  their `discipline.*_globs` overrides for lane inference — patterns only, applied to a
  static file list; never its run-diff source (`implement.json` does not exist here).
- Follow: GOTCHAS.md "subprocess on Windows is not a shell" for every git call from the
  Python body — resolve `git` explicitly, `encoding="utf-8", errors="replace"`.
- Reuse: Stage 6's close-out ordering in `skills/sdlc/templates/stage-6-handoff.md` — the
  regenerate step runs right after `close-tasks.sh close` and before gotcha capture, so a
  run that dies at the confirm prompt still leaves a current file.
- Reuse: the **Park protocol** in `skills/sdlc/templates/queue-mode.md` for an empty now-wave.
- Reuse: the print-then-dispatch rule `model: <tier> (cap: <cap|none>)` from
  `skills/sdlc/templates/models.md` for the reassess agent (Axis 1, Sonnet by default).
- Follow: "gate in the skill, body in the template" — the reassess body is a new template
  that a default run never opens.
- Follow: every new config key lands in `templates/project.json.example` (with a
  `_comment`) **and** `docs/CONFIG.md`.
- New (justified): row tags `_after: <plan>[:<phase>]_`, `_conflicts: <plan>[:<phase>]_`,
  `_lane: <name>_`. Rows have no stable ids, so references name a plan or plan phase, which
  are durable; a row's own linked task file (`plans/tasks/task-N-<slug>.md`) is also accepted.
- New (justified): `close-tasks.sh tag` — the only writer of those tags, so a model never
  edits `TASKS.md` trailers by hand and never touches checkbox state.

### Implementation Steps

#### Phase 1 — Deterministic waves (no model calls)

1. **Row-tag grammar.** Parse `_after:`, `_conflicts:` and `_lane:` in `parse_row`
   (`scripts/close-tasks.sh`). Document them in `templates/TASKS.md.template` next to
   `_manual_` / `_followup_`, and in `docs/BOARD-JSON.md` if `board` exposes them. Also add a
   per-step `Files:` line convention to `skills/brainstorm/templates/plan.md.template` (it is
   what step 2 parses; existing plans use it only sometimes).
   Files: `scripts/close-tasks.sh`, `templates/TASKS.md.template`, `docs/BOARD-JSON.md`, `skills/brainstorm/templates/plan.md.template`.
2. **`close-tasks.sh waves`** (read-only by default). Inputs: `TASKS.md`, each open row's
   plan file (the `#### Phase N` section's file paths), `.claude/pipeline/*/run.json`.
   - File extraction for a row's plan phase: every step-level `Files:` line in that
     `#### Phase N` section, plus backticked repo paths in the section that exist on disk;
     a phase with neither yields no files (→ `unknown_files[]`).
   - Candidates: open `Active / Pending` rows. `_manual_` rows go to a `needs_you[]` list;
     `Blocked` rows are excluded.
   - Order edges: within one `_plan:`, a row waits while a lower `_phase:` of that plan has an
     open row; an explicit `_after:` adds an edge (and overrides inference).
   - Conflict edges: explicit `_conflicts:`, plus inferred — two rows whose plan-phase file
     lists intersect. A row with no resolvable files has no inferred conflicts (parallel by
     default) and is reported under `unknown_files[]` so the gap is visible.
   - Lanes: explicit `_lane:` > the surfaces of its files via the changed-files-gate globs >
     `general`.
   - **now** = rows with no open order edge, at most one per lane (highest priority, `[~]`
     first), and no two that conflict. **next** = rows that become ready if every now row
     closes.
   - Output: JSON on stdout (`{now: {<lane>: row}, next: {<lane>: [rows]}, needs_you,
     unknown_files, overlaps}`); `--write <path>` also renders `ACTION_ITEMS.md` laid out by
     lane, with a "generated — edit TASKS.md, not this file" banner and the generating command.
   Files: `scripts/close-tasks.sh`.
3. **Worktree overlap warning.** In `waves`, read `git worktree list --porcelain`, then each
   worktree's `git diff --name-only HEAD` plus untracked files (read-only git only, with the
   Windows subprocess rule above). A now row
   whose files intersect another worktree's dirty set gets `overlaps: [{worktree, branch,
   files}]` and a ⚠ line in the rendered file. Skip silently outside git.
4. **Tests.** Extend `close-tasks.sh`'s existing CI harness with scratch `TASKS.md` + plan
   fixtures: within-plan phase order, `_after:` override, inferred file conflict, one-per-lane,
   `_manual_` → `needs_you`, no-files → parallel + `unknown_files`, a worktree overlap, and an
   empty now-wave.
   Files: `scripts/ci/test-hooks.sh`.

#### Phase 2 — Wire it into the pipeline

5. **Config.** `pipeline.action_items.enabled` (default `false` — but also ON whenever
   `ACTION_ITEMS.md` already exists, so creating the file once opts a repo in),
   `pipeline.action_items.file` (default `ACTION_ITEMS.md`), `pipeline.action_items.reassess`
   (default `false`). Both `templates/project.json.example` and `docs/CONFIG.md`.
6. **Stage 6 regenerate.** In `skills/sdlc/templates/stage-6-handoff.md`, right after the
   close-out script: when enabled, run `close-tasks.sh waves --write <file>` and copy its
   JSON summary into `handoff.json` `data.waves`, and patch `skills/sdlc/templates/state-schema.md`'s
   `handoff` shape to document `data` (today's `data.tasks` is undocumented too) and `data.waves`. Gate sentence in `skills/sdlc/SKILL.md`
   Stage 6 is unnecessary (it's a step of an always-loaded template); one line in Stage 7's
   report: `waves: now N across L lane(s), next M` plus any overlap warning.
7. **Queue selection.** In `skills/sdlc/templates/queue-mode.md` step 1: when enabled, select
   from `waves` now (priority within it) instead of plain priority, and call
   `close-tasks.sh waves --write` explicitly between items — the existing re-scan only
   re-reads `TASKS.md`, it does not regenerate the waves. An empty now-wave **parks** via the Park protocol with
   the reason (`needs_you` rows, blocked rows, or nothing open).
8. **`/sdlc-status`.** One line from `close-tasks.sh waves` (read-only, no `--write`) plus
   overlap warnings, in `skills/sdlc-status/SKILL.md`.
9. **Overlays.** `copilot/skills/sdlc/SKILL.md` and `codex/skills/sdlc/SKILL.md` — they
   already point at the shared templates; add only what differs (nothing, if they load
   `stage-6-handoff.md` and `queue-mode.md` unchanged — confirm).
10. **Ignore rule.** `ACTION_ITEMS.md` is regenerable state: add it to `setup.sh`'s
    always-ignored machine-state entries and to `/repo-onboarding`'s Step 5 machine-state list.
    Deliberately unlike `TASKS.md` / `project.json` (which onboarding asks about): it is derived,
    so there is nothing to share that `TASKS.md` doesn't already carry.

#### Phase 3 — Reassess (opt-in) and the Jev seam

11. **`close-tasks.sh tag`.** `tag --row <unique needle> --add|--remove '<tag>'`: validates
    tag grammar, that a referenced plan (and phase) exists, and that the needle matches exactly
    one open row; edits only the trailer, never checkbox state; idempotent.
12. **Reassess step.** New template `skills/sdlc/templates/action-items-reassess.md`, opened
    from Stage 6 only when `pipeline.action_items.reassess` is true **and** the open-row set
    changed since the last `waves` run (hash in the bare file `.claude/pipeline/.action-items-hash`
    — never a subdirectory, which envelope-staleness and `board` would read as an orphaned run). One Sonnet
    agent (print the model line) gets the `waves` JSON plus the plan-phase excerpts for now and
    next rows, and returns proposed tags, each with a quoted line of evidence. The
    orchestrator applies each through `close-tasks.sh tag`, then regenerates. Never more than
    one agent per run.
13. **Jev seam (docs only).** In `docs/plans/jev-integration.md`, park three judge verbs —
    `depends-on` (Noul), `classify-lane` (Choice), `conflicts` (Noul) — as the reassess
    step's future backend: shadow first (record what it would tag beside the agent's
    proposals), a verdict cache keyed by the hash of both rows, and the plan's existing bands
    (< 0.30 no / 0.30–0.70 uncertain → listed in `ACTION_ITEMS.md` as "possible", never
    tagged / > 0.70 tag).
14. **Version bump.** `.claude-plugin/plugin.json` and `marketplace.json`.

### Cross-Module Touchpoints

- **`/sdlc` (+ overlays)**: Stage 6 regenerate, Stage 7 line, `--queue` selection.
- **`/sdlc-status`**: the waves line and overlap warnings.
- **`/brainstorm`**: none required — it already writes `_plan:` / `_phase:` tags, which is
  all inference needs; it may later write `_after:` when a plan names a cross-plan dependency.
- **`scripts/close-tasks.sh`**: `waves` and `tag` subcommands; `board` may expose the new tags.
- **`setup.sh` / `/repo-onboarding`**: `ACTION_ITEMS.md` joins the machine-state ignore list.
- **Jev**: future backend for reassess, behind `jev-integration`'s judge seam.

### Open Questions

Decided by the owner (2026-10-02): generated file from tags; now + next wave; human launches
parallel sessions; inference + agent reassess hybrid; Stage 6 add-on, no new skill; empty
now-wave parks. Decided here, revisit if wrong:
- One active row **per lane** in the now wave (Expo Rail). If two backend rows touch disjoint
  files this under-reports parallelism; the conflict edges could replace the per-lane cap
  later.
- `ACTION_ITEMS.md` is always gitignored (it is derived). If you want it in PR descriptions,
  paste the `waves` output instead.
- Enabled by presence of the file as well as by the key, so trying it is one command.

### Appendix: Alternatives Considered

- **B — standalone `/action-items` skill**: rejected; ~400 more always-resident description
  characters against a nearly full budget, and two entry points to one behaviour.
- **C — `/sdlc-status --waves` only**: rejected as the whole answer (a view, not a guide), but
  it is step 8 of this plan.
- **Wildcard: Worktree Diff Oracle** (first principles — measure conflicts from dirty
  worktrees instead of predicting): grafted as the overlap warning (step 3), not the whole
  model — it sees nothing before a worktree opens.
- **Wildcard: CONFLICTS.md / parallel-by-default** (inversion): grafted as the default
  stance; a positive `_after:` stays for true ordering (a migration before its reader).
- **Wildcard: Expo Rail** (restaurant kitchen): grafted as the by-lane layout and the
  one-active-row-per-lane rule.
- **Wildcard: Ephemeral board** (constraint removal — no file, print on demand): rejected as
  the owner wants a file; `waves` without `--write` is exactly this mode.
- **Fall back to priority on an empty now-wave**: rejected; it would start work whose
  dependency is not done.
- **Toolkit-run parallel waves** (one `/sdlc` per lane in its own worktree): rejected for now;
  overlaps the parked `/sdlc --detach` idea in `TASKS.md`.
