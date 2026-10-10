## Brainstorm Result: Backlog follow-ups — waves noise, title fix, key migration, bug hunts

> Written 2026-10-10 with the owner. Four follow-ups from the ACTION_ITEMS waves / models work:
> (1) inferred-conflict noise from files every plan names, (2) the title-mangling bug in
> `TAG_STRIP_RE`, (3) auto-migrating dead `.claude/project.json` keys, (4) bug hunts —
> decided earlier from a review of another repo's bug-hunter / bug-squasher / red-check skills:
> **bugs are `TASKS.md` rows tagged `_bug_`, not a separate `BUGS.md`; no new skill.**

### Direction

Four independent phases, smallest and most mechanical first so each `/sdlc` run (the scope gate
takes one phase) ships something whole. Phase 1 fixes two `close-tasks.sh` defects measured on a
real backlog: 40 of 47 inferred-conflict file hits were `plugin.json` / `marketplace.json`, named
by every plan's version-bump step, and `board`/`waves` turn the title "Row tags
`_after:/_conflicts:/_lane:` parsed…" into "Row tagsconflicts:/plan: …". Phase 2 turns the
key-rename table that today lives only as prose (`docs/MODEL-AXES.md`, the dead-key rows in
`scripts/ci/forbidden-phrases.txt`) into a deterministic, idempotent migration that setup,
onboarding and `/sdlc` Stage 0 run — an old key currently falls back to the default silently.
Phases 3-4 make bugs first-class without a new skill or a second backlog: a `_bug_` row tag that
`rows`, `board`, `waves` and `/repo-health` understand, a red-check rule in the fix loop, a
bug-triage template `/sdlc` loads only for bug rows, and a `/repo-health --hunt` mode that files
evidence-backed bug rows. Device/emulator driving stays out of core (it is the extras plugin's
`device-truth` row).

### Conventions & reuse

- Follow: `close-tasks.sh`'s shape — bash dispatcher over one embedded Python body, JSON on
  stdout, read-only unless a write flag says otherwise, five wiring sites per subcommand/flag
  (usage, bash flag loop, bash `case`, Python Args + parser, `if sub ==`) — see `do_waves`,
  `do_tag` in `scripts/close-tasks.sh`.
- Reuse: `parse_row` / `trailer` / `open_kind` / `TAG_STRIP_RE` / `MANUAL_RE` in
  `scripts/close-tasks.sh` for the title fix and the `_bug_` flag; `section_files` /
  `files_intersect` for the hub-file rule.
- Reuse: `scripts/py.sh` for every Python entry point; the `merge-hook.py` style for a
  value-preserving JSON rewrite; `setup.sh`'s `copy_if_new` neighbourhood for where setup
  touches `.claude/project.json`.
- Reuse: `skills/repo-health/SKILL.md`'s existing agent-check fan-out and scoring formula for the
  open-bugs check and the hunt lenses; `skills/sdlc/templates/fix-loop.md` for red-check;
  `skills/sdlc/templates/models.md` for the new `models.hunt` key (Axis 1, Sonnet default).
- Follow: gate in the skill, body in the template (`bug-triage.md`, `repo-health/references/hunt.md`
  load only when needed); every new key in `templates/project.json.example` + `docs/CONFIG.md`;
  a per-phase version bump (`check_contracts.py` version-freshness).
- New (justified): `scripts/migrate-project-json.sh` — no existing script rewrites a consumer's
  config; the rename table must be data, not prose, or it drifts.

### Implementation Steps

#### Phase 1 — close-tasks.sh: title fix and hub-file noise

1. **Title fix.** `TAG_STRIP_RE` strips any `_key: value_`-shaped text anywhere in the row, so a
   title that *mentions* tag syntax is mangled (reproduces at the commit before this plan).
   Strip tags only from the trailer (after the last ` — `), leave the title body verbatim.
   Tests: the literal row "Row tags `_after:/_conflicts:/_lane:` parsed in close-tasks.sh … —
   … `_plan: x_ · _phase: 1_`" keeps its title in `board` and `waves`; normal rows unchanged.
   Files: `scripts/close-tasks.sh`, `scripts/ci/test-hooks.sh`.
2. **Hub files.** A file named by the plan-phase file lists of ≥ `pipeline.action_items.hub_threshold`
   distinct plans (default 3) is a *hub*: excluded from inferred conflicts and reported in a new
   `hub_files[]` (+ `summary.hub_files`). Also `pipeline.action_items.ignore_conflict_files`
   (default `[]`, globs) for files a repo always wants ignored. Explicit `_conflicts:` tags are
   unaffected. Measure before/after on this repo's `TASKS.md` and record the counts in the commit.
   Tests: three plans naming `plugin.json` → no conflict, file in `hub_files`; two plans → still a
   conflict; an ignore glob; an explicit `_conflicts:` still wins.
   Files: `scripts/close-tasks.sh`, `scripts/ci/test-hooks.sh`, `templates/project.json.example`,
   `docs/CONFIG.md`, `docs/BOARD-JSON.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

#### Phase 2 — auto-migrate dead project.json keys

3. **Rename table as data.** `scripts/project-json-renames.json`: `[{old, new, note}]` for every
   row of `docs/MODEL-AXES.md`'s migration table (`pipeline.sanity_check.model` →
   `models.sanity`, `pipeline.sanity_check.focuses` → `agents.sanity_focuses`,
   `pipeline.review_fix.model` → `models.code_review`, `pipeline.review_fix.second_pass_model`
   → `models.code_review_second_pass`, `pipeline.review_fix.lenses` → `agents.code_review_lenses`,
   `pipeline.review_fix.passes` → `agents.code_review_passes`,
   `pipeline.review_fix.max_fix_loops` → `agents.code_review_max_fix_loops`,
   `pipeline.decompose_min_tasks` → `agents.decompose_min_tasks`) plus `models.focuses` →
   `agents.sanity_focuses` (seen in a consumer repo). CI (`check_contracts.py`): every dead-key
   row in `forbidden-phrases.txt` and every MODEL-AXES migration row has a table entry, and every
   `new` exists in `templates/project.json.example`.
   Files: `scripts/project-json-renames.json`, `scripts/ci/check_contracts.py`.
4. **`scripts/migrate-project-json.sh`** (bash + embedded Python via `py.sh`):
   `check [--file .claude/project.json]` → JSON `{moves[], conflicts[], unknown[]}`, exit 0;
   `apply` → rewrites value-preserving (keeps `_comment` / `//` keys and key order where
   possible), timestamped `.bak` first, never overwrites a `new` key that already holds a
   different value (reports a conflict, leaves both), drops an `old` key only when its value
   moved or equals the existing `new`; idempotent; preserves line endings; prints each move.
   `unknown[]` lists keys not in the example (the same check `docs/CONFIG.md` "Check your file"
   gives as a one-liner — point that section at this script).
   Tests: each rename; conflict left alone; idempotent second run; comments kept; CRLF file;
   missing file → no-op.
   Files: `scripts/migrate-project-json.sh`, `scripts/ci/test-hooks.sh`, `docs/CONFIG.md`.
5. **Wire it.** `setup.sh`: when `.claude/project.json` exists, run `apply` and print the moves.
   `/repo-onboarding`: run `check` before proposing and offer `apply`; also detect an alembic
   tree (`**/alembic/versions`) and a frontend root not named `frontend/` (e.g. `portal/` with
   `package.json` + `.ts/.tsx`) and propose the matching `discipline` globs — the default data
   glob `**/migrations/**` misses alembic. `/sdlc` Stage 0: run `check`; print one warning line
   per dead key (`<old> is ignored — rename to <new>; run migrate-project-json.sh apply`) and
   continue. Version bump.
   Files: `setup.sh`, `skills/repo-onboarding/SKILL.md`, `skills/sdlc/SKILL.md`,
   `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`, `.claude-plugin/plugin.json`,
   `.claude-plugin/marketplace.json`.

#### Phase 3 — bugs as TASKS.md rows, red-check, triage

6. **`_bug_` row flag.** Parsed from the trailer like `_manual_` (`parse_row` → `bug: bool`);
   severity is the existing `(P0)`-`(P3)` priority — no second scale. `rows`/`board` gain
   `--tag bug`; `board` exposes `bug`; `waves` lists bug rows first within a lane, adds
   `summary.bugs`, and caps rendered bug rows per lane (`pipeline.action_items.max_bugs_per_lane`,
   default 5, rest counted) so a large bug backlog can't swamp the file; `tag` accepts `bug`.
   A bug row's narrative lives in its hunt report (step 10), linked from the row text.
   Document the tag in `templates/TASKS.md.template` and the README backlog table.
   Files: `scripts/close-tasks.sh`, `scripts/ci/test-hooks.sh`, `templates/TASKS.md.template`,
   `templates/project.json.example`, `docs/CONFIG.md`, `docs/BOARD-JSON.md`, `README.md`.
7. **Red-check in the fix loop.** In `skills/sdlc/templates/fix-loop.md` (and `/task`'s TDD loop
   if it has its own wording): a regression guard test only counts if it **fails with the fix
   reverted** — revert the fix in the working tree (not via git writes: re-apply the inverse
   edit), run the one test, restore; plus a short weak-red-check list (asserts on mocks it set up
   itself, asserts only "no exception", snapshot regenerated with the fix, test never imports the
   changed code, guard skipped/xfail'd). Source for the list: the red-check skill reviewed in
   another repo; adapt, don't copy repo-specific bits. ≤25 lines.
   Files: `skills/sdlc/templates/fix-loop.md`, `skills/task/SKILL.md`.
8. **Bug triage template.** `skills/sdlc/templates/bug-triage.md`, loaded from `/sdlc` Stage 0
   **only** when a resolved row carries `_bug_` (gate sentence in `skills/sdlc/SKILL.md`):
   classify FIXABLE vs NEEDS-A-HUMAN (data, fact, product decision, schema, legal copy, spend,
   credential); split rather than block (fix the fixable half now, file the human half as a
   `_manual_` row); MITIGATED is a valid outcome; verify by effect, not by a passing test alone.
   Files: `skills/sdlc/templates/bug-triage.md`, `skills/sdlc/SKILL.md`,
   `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`.
9. **`/repo-health` open-bugs check.** A cheap procedural check counting open `_bug_` rows by
   priority via `close-tasks.sh rows --tag bug`; add a weighted term to the existing score
   (P0/P1 heavy, P2/P3 light) and list the top few in the report. Version bump.
   Files: `skills/repo-health/SKILL.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

#### Phase 4 — `/repo-health --hunt`

10. **Hunt mode.** `/repo-health --hunt [<area>]` loads `skills/repo-health/references/hunt.md`
    (gate in the skill; a default run never opens it): fan out `agents.hunt_lenses` lenses
    (default 3: correctness, error handling / edge cases, data & contracts) on `models.hunt`
    (Axis 1, default `sonnet`); **evidence rule** — a finding needs a `file:line` plus a quoted
    line, a failing command with its output, or a measured value, otherwise it goes under
    "Unverified" and files nothing; one consolidator pass re-verifies each finding against the
    code and may overrule a lens (`models.code_review` tier — a different, stronger model);
    dedupe against open `_bug_` rows by `file:line`; write the hunt report to
    `plans/bug-hunts/<date>-<slug>.md` (`docs/plans/bug-hunts/` in a skill repo) and append one
    `_bug_` row per confirmed finding (capped, `(P0)`-`(P3)` from severity, linking the report).
    Read-only on code — it files rows, never fixes. Copilot/Codex: lenses run sequentially
    (overlay note only if a repo-health overlay exists). Description: append at most ~15
    characters to `/repo-health`'s description (currently 535 of the 550 target).
    Files: `skills/repo-health/SKILL.md`, `skills/repo-health/references/hunt.md`,
    `skills/sdlc/templates/models.md`, `templates/project.json.example`, `docs/CONFIG.md`,
    `README.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.
11. **Tests and evals.** `test-hooks.sh` cases for `rows --tag bug`, the waves cap, and the hub
    rule interacting with bug rows; a `skill-eval` scenario for `--hunt` on the fixture repo
    (planted bug → one row filed with evidence; clean file → nothing filed) if the harness
    supports read-only skills cheaply.
    Files: `scripts/ci/test-hooks.sh`, `scripts/ci/skill-eval.py`.

### Cross-Module Touchpoints

- `scripts/close-tasks.sh`: title fix, hub files, `_bug_` flag, `--tag bug`, waves bug ordering/cap.
- `/sdlc`: Stage 0 dead-key warning and bug-triage gate; fix loop red-check.
- `/repo-onboarding` and `setup.sh`: migration + alembic/frontend glob proposals.
- `/repo-health`: open-bugs check and `--hunt`.
- `/sdlc-status`: nothing required (its waves line inherits `summary.bugs` if printed).
- Extras plugin: device-driving bug hunts stay there.

### Open Questions

- Should `migrate-project-json.sh apply` run automatically on `setup.sh` re-runs, or only print
  `check` and ask? (Plan: apply with a backup, because a dead key silently does nothing.)
- Import path for a repo that already keeps a `BUGS.md`: a one-shot `close-tasks.sh import-bugs`
  converting open entries to `_bug_` rows — deferred until a consumer needs it.

### Appendix: Alternatives Considered

- **A separate `BUGS.md` store** — rejected: a second backlog drifts from `TASKS.md` (observed in
  the reviewed repo), and every existing tool already reads rows.
- **A standalone bug-hunter skill** — rejected: ~450 characters of the ~650 left in the
  always-resident description budget, and its device-driving body is not portable.
- **Hub files by fixed list** (`plugin.json`, `marketplace.json`) — rejected as the only rule:
  repo-specific; the threshold rule generalises, the ignore list covers the rest.
- **Migration as prose only** — that is today's state, and it failed silently in a consumer repo.
