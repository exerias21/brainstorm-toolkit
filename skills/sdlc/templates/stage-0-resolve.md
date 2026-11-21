# Stage 0 — Resolve input (body)

Loaded by `skills/sdlc/SKILL.md` Stage 0. The skill keeps the gates (scope-gate skip rule, vendored-skill guard, skill-repo detection); this file holds the procedure.

Detect the argument shape:

1. **Plan file** — arg is a path ending `.md` that exists (e.g.
   `plans/my-feature.md`). Use it as the plan and parse it per Stage 0 below.
   This is the primary path and the one that exercises the full pipeline
   (Stage 5's plan check has a plan to check against). **Look up this plan's
   `TASKS.md` rows by calling `scripts/close-tasks.sh rows --plan <slug>
   --plan-file <path>`** — compute `<slug>` here using the **Derive `slug`** rule
   below (basename minus extension, minus a leading `brainstorm-` /
   `team-brainstorm-` / `pbi-NNN-` / `task-NNN-` prefix) **before** this call, not
   the raw basename: `/brainstorm` tags rows with the *stripped* slug
   (`_plan: add-orders_`, never `_plan: brainstorm-add-orders_`), so pass the
   stripped slug, never the raw basename — never `reconcile | grep <slug>`: `reconcile` only reports drift against
   *existing* pipeline envelopes, so on a first run for this plan it always
   returns zero rows even though correctly-tagged rows are sitting open. `rows` reads TASKS.md alone, matching the
   `_plan: <slug>_` marker `/brainstorm` appends, with a legacy path-substring
   fallback for untagged rows. **Do not mark any row `[~]` yet** — the
   **Scope gate** below (after `parse.json`) decides which of these rows are
   in scope for this run and marks only those; Stage 6 closes taken rows via
   `scripts/close-tasks.sh`. A plan-file run whose `rows` call returns no
   `matched[]` updates no `TASKS.md` — that's expected, not a miss.

2. **Task id** — arg matches `task-NNN` or a bare row number. Read that
   `TASKS.md` row and its linked `plans/tasks/task-N-<slug>.md`. The task
   file's `parent_plan:` frontmatter (if present) becomes the flowsim / Stage 5
   plan target. Mark the row `[~]` (not under `writer: "orchestrator"`).

3. **Task range** — arg is `N-M`, `task-N..task-M`, or `tasks N-M`. Resolve
   every `Active / Pending` row in that inclusive range to its task file.
   Execute them as a batch (see Stage 6 range semantics). Record the resolved
   ids in `run.json.data.task_range`. Mark each resolved row `[~]` (not under `writer: "orchestrator"`), **except a
   `_manual_` row** — leave it `Active / Pending` and report it, never execute it.

4. **Ad-hoc description** — anything else. Create a new `TASKS.md` row + task
   file using `/task`'s procedure (`skills/task/SKILL.md` Sections 1–2), which
   at its own step 5 already writes `.claude/pipeline/task-<N>-<slug>/run.json`
   at `in_progress`. **This run's slug IS that `task-<N>-<slug>`** — one
   envelope, not two — the same rule `skills/sdlc/templates/queue-mode.md`
   already applies to a row with a linked task file ("uses that task slug
   instead"). Do not derive a second slug from the description text here: doing
   so leaves the `/task`-written envelope `in_progress` forever, which feeds
   `next-action.sh`'s stale-run warning on every Stop and makes `stop-gate.sh`
   re-run tests indefinitely under `pipeline.stop_gate: "tests"`. **Adopting this
   envelope means `/sdlc` owns it**: set `run.json.pipeline: "sdlc"` (not `"task"`)
   and record the additive `data.adopted_from: "task"` (`state-schema.md`). There's no
   plan, so Stage 5's plan check self-skips. Mark the new row `[~]`.

**Task id / range / ad-hoc-description runs have no `_plan:` key** (that tag only exists
on plan-file rows), so Stage 6 can't close them by key. Instead, **persist the resolved row
id(s) at Stage 0** into `run.json.data.tasks.resolved[]` — one entry per row, each a
substring unique to that row (its linked task file path, e.g.
`plans/tasks/task-N-<slug>.md`, is the natural choice). Stage 6 closes **exactly** these
entries via `scripts/close-tasks.sh close --scope resolved`, never a fuzzy match — this is
also what makes a task-id `--resume` (which skips Stage 0) work: it re-reads this same
array from the existing envelope rather than re-deriving anything from session memory.

5. **Queue mode** — arg is `--queue [N]`. Select the work set from `TASKS.md` **by
   state + priority** (not a hand-typed range): the `Active / Pending` rows, top
   `N` (or `pipeline.loop.max_items`, default 5) by priority `P0 > P1 > P2 > P3`, an
   `[~]` in-progress row first. Then loop the pipeline over them with a re-scan and
   stop conditions — see **Queue mode** in the skill (that re-scan is what makes it a loop,
   not a one-shot range).

Mark resolved rows `[~]` (in-progress; never under `writer: "orchestrator"`) — cases 2–5 mark immediately; case 1 (plan file) marks
only the rows the **Scope gate** below takes, once `parse.json` exists to size them. Derive
`slug`: the plan filename minus its extension, minus a leading
`brainstorm-` / `team-brainstorm-` / `pbi-NNN-` / `task-NNN-` prefix, lowercased, every character
outside `[a-z0-9-]` replaced with `-`, runs collapsed, ends trimmed; it must match
`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` or the run stops with a clear error (maintainer record:
`docs/CONVENTIONS.md`). Capture `base_commit` = `git rev-parse HEAD` and
initialize the state envelope at `.claude/pipeline/<slug>/` with
`pipeline: "sdlc"`, `base_commit`, `status: "in_progress"`, `args.toolkit_version` (the plugin's `plugin.json` `version`).

**Dirty-at-start snapshot (envelope creation only, never on `--resume`).** Right after `base_commit`, record
`run.json.data.dirty_at_start` and `data.live_envelopes` (`skills/sdlc/templates/state-schema.md`). Another session's
uncommitted files in a shared worktree otherwise land in this run's hand-off and review scope. Run
`git status --porcelain -z --untracked-files=all`, drop `.claude/pipeline/`, take a rename's new path (the old path is
dirty too), and store `{path: <git hash-object of the file, or "deleted">}`. `live_envelopes` is informational only (a
crashed run stays `in_progress`); nothing gates on it.

**Report-rows mode (`pipeline.tasks.writer`, default `"self"`).** Record the resolved value in `run.json.data.tasks.writer`.
Under `"orchestrator"` a delegated run never edits `TASKS.md` — the orchestrator owns those writes, and two writers race:
cases 2–5 mark no row `[~]`; the scope gate records the taken rows' unique substrings in `data.tasks.resolved[]` instead of
marking them; an ad-hoc description creates no row and no task file (skip `/task`'s procedure, derive the slug as for a plan,
and carry the would-be row to `tasks_report.add`); `--queue` stops with one line (`--queue needs TASKS.md writes; set
pipeline.tasks.writer to "self"`). Stage 6 reports the rows instead of editing them
(`skills/sdlc/templates/stage-6-handoff.md`).

**Independence pre-check (before any spend).** If the review stage resolves ON
(`pipeline.review_fix.enabled: true`; `--no-review` always wins OFF), compute whether `models.code_review` collides with the implementer's effective tier per
`skills/sdlc/templates/models.md` "Independence" — **do not open
`skills/sdlc/templates/stage-5.7-review-fix.md` for this**, it is opt-in and a default run must
never load it. On a collision, print the same degraded line Stage 5.7 emits before dispatching
now, before Stage 1.5 spends a token, rather than only surfacing it once Stage 5.7 runs.

**Then parse the plan.** Read the resolved plan/task file(s) fully and extract:
feature name/slug; implementation steps (numbered lists with file paths, or
checkbox rows); files to create or modify (file paths, a table of files, or each
linked task file's `files:` frontmatter); acceptance criteria ("expected",
"should", "must", "verify" language); cross-module touchpoints; when present, the `### Premises`, `### Baseline & exit measurement`
and `### Pins and forward behaviour` sections. A `TASKS.md`-style
checkbox list counts every `[ ]`/`[~]` row in `Active / Pending` as an
implementation step.

**Write `stage-outputs/parse.json`** with `data.feature_name`,
`data.files_to_change`, `data.implementation_step_count`,
`data.acceptance_criteria_count`, `data.premises[]`, `data.baseline` (string or null) and
`data.pins[]` (`{kind: "pin"|"forward", text}`; empty/null when the plan has no such
section), and append `parse` to
`run.json.stages_completed`. This is not bookkeeping: Stage 2's decompose gate
reads `data.files_to_change` and `data.implementation_step_count` and cannot run
without them.

## Scope gate (plan-file runs only)

Immediately after `parse.json` is written, decide how much of this plan to take **this run**.
Skip this gate entirely for task-id / range / ad-hoc / `--queue` inputs — each is already
bounded to one row or an explicit range — and for `--no-scope-gate`, which forces whole-plan
execution (`taken` = every open row). Under `pipeline.tasks.writer: "orchestrator"` the scope gate never runs, so
record every open row's unique substring (from the `close-tasks.sh rows` result) in `data.tasks.resolved[]` yourself,
or the Stage 6 close preview is empty.

**Read `skills/sdlc/templates/scope-gate.md` now** and follow it: it sizes the plan, prefers the
plan's own phase boundaries, handles a plan with zero rows and `_manual_`-only phases, runs a
warn-only reconcile check before taking, records `run.json.data.scope_gate` (accumulating
`taken_phases` across re-runs), and prints the verdict line.

**Bug rows.** If any taken or resolved row carries `_bug_` in its trailer (the `bug` field from `close-tasks.sh rows`; for a task-id, range or queue item, the row itself), **read `skills/sdlc/templates/bug-triage.md` now**; otherwise never open it.

**Native task mirror (Claude only; skip silently elsewhere).** Once the stage list for this run
is known, call `TaskCreate` once per stage that will actually run — the gates above have already
decided which those are, so a review-off run creates no `review` task. Mark each `in_progress` on
entry and `completed` on its sidecar write; a paused run leaves its stage `in_progress`, which is
the correct reading.

This is a **progress indicator, not state.** The durable record is `run.json` +
`stage-outputs/`; `TASKS.md` is the durable backlog. The native list is session-scoped and
Claude-only, so nothing may read it back — never let a decision depend on it. What it buys is a
live view of a long run *outside* the context window: the stage narration it replaces is re-read
by every later turn, the task list is not. That is why this is worth the calls.

## Continuity detection (prompt, never auto)

The shared scan in
`skills/sdlc/templates/envelope-staleness.md`: **skip entirely when on the
`main_branch`** (merges make every run an ancestor there — pure noise). On a
feature branch, take only the **single most-recently-updated** run whose
`base_commit` is an ancestor of HEAD, and prompt **only** if it's non-terminal OR
complete with HEAD advanced past that `base_commit` (follow-up landed outside the
pipeline). One prompt at most, or none.
