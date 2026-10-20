## Brainstorm Result: Multi-session process retro, Phase 4 (multi-session safety, report-rows mode, long gates)

### Direction
Ship the rest of Phase 4 of `docs/plans/multi-session-process-retro.md`. Its step 7 (opt-in
`safe-commit` hand-off) is **dropped** per DECISIONS.md (2026-10-19): `/sdlc` keeps its no-git-writes
contract. The work board stays repo-local (the parent plan's recommendation) until a second repo
needs it. That leaves three additive changes, each inert for a single-session repo with default config:

- **Dirty-at-start exclusion.** When two sessions share a worktree, the other session's uncommitted
  files were swept into this run's hand-off and review scope. Stage 0 records the paths already
  dirty and the other live envelopes; the hand-off's `files_changed`, the suggested `git add` and the
  review/cleanup scope exclude those paths, and any dirty-at-start path this run also edited is
  listed as `shared` so the user stages it by hunk.
- **Report-rows mode.** With `pipeline.tasks.writer: "orchestrator"`, a delegated run never edits
  `TASKS.md`: Stage 0 does not mark rows `[~]`, and Stage 6 lists the rows it would close and the
  re-entry rows it would add (in `handoff.json` and the report) for the orchestrator to apply.
  Default `"self"` keeps today's behaviour.
- **Long gates run in the background.** A suite longer than the 10-minute foreground tool limit was
  reported "partial". The test-runner starts any command that may exceed the limit once with
  `run_in_background` and waits for its completion notice; a foreground timeout is never reported as
  a result.

Version stays 0.18.25 (Phases 1–3 are uncommitted in the same tree).

### Conventions & reuse
- Follow: additive `run.json.data.*` fields documented in the `run.json` table of
  `skills/sdlc/templates/state-schema.md` (as `data.scope_gate`, `data.tasks.resolved`).
- Follow: `pipeline.tasks.*` keys already exist in `templates/project.json.example`
  (`close_in_place` with `_close_in_place_comment`); add `writer` beside it.
- Follow: Stage 6 close-out runs through `scripts/close-tasks.sh` (`stage-6-handoff.md` step 3);
  report-rows mode uses its read-only `rows` subcommand instead of `close`, never a hand edit.
- Follow: review/cleanup scope is `implement.json` `data.files_changed[].path`
  (`stage-5.9-cleanup.md`, `changed-files-gate.md`); filter there.
- Follow: `agents/test-runner.md` "Timeout or hang" rule is where the background-run rule goes.

### Implementation Steps

#### Phase 4 — Multi-session safety, report-rows mode, long gates
1. **Stage 0 snapshot.** After `base_commit`, record `run.json.data.dirty_at_start` (paths from
   `git status --porcelain`, untracked included) and `data.live_envelopes` (slugs of other
   `.claude/pipeline/*/run.json` with `status: "in_progress"`). Canonical skill and both overlays;
   fields in `state-schema.md`.
   Files: `skills/sdlc/SKILL.md`, `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md`,
   `skills/sdlc/templates/state-schema.md`
2. **Exclude them downstream.** The Stage 2 state write drops `dirty_at_start` paths that this run did
   not touch from `files_changed` (a path in both is kept and flagged `shared: true`). Stage 6's diff
   report and suggested `git add` list only this run's files and print `shared` paths with "stage by
   hunk". The review (5.7) and cleanup (5.9) scopes inherit it from `files_changed`, so they need one
   line each confirming they never widen past it.
   Files: `skills/sdlc/SKILL.md`, `skills/sdlc/templates/stage-6-handoff.md`,
   `skills/sdlc/templates/stage-5.7-review-fix.md`, `skills/sdlc/templates/stage-5.9-cleanup.md`,
   `skills/sdlc/templates/state-schema.md`
3. **Report-rows mode.** `pipeline.tasks.writer` (`"self"` default | `"orchestrator"`). Under
   `orchestrator`: Stage 0 marks nothing `[~]`; Stage 6 step 3 runs `close-tasks.sh rows` (read-only)
   instead of `close`, writes `handoff.json` `data.tasks_report = {close: [...], add: [...]}` and prints
   them; the re-entry rows go into `add` instead of `TASKS.md`; `--queue` refuses this mode with one
   line (its re-scan needs the writes). Example key and `_comment` in `project.json.example`, row in
   `docs/CONFIG.md`. Mirror the Stage 0 and Stage 6 gate in both overlays.
   Files: `skills/sdlc/SKILL.md`, `skills/sdlc/templates/stage-6-handoff.md`,
   `skills/sdlc/templates/queue-mode.md`, `skills/sdlc/templates/state-schema.md`,
   `templates/project.json.example`, `docs/CONFIG.md`, `copilot/skills/sdlc/SKILL.md`,
   `codex/skills/sdlc/SKILL.md`
4. **Long gates.** `agents/test-runner.md`: a command that may run past the 10-minute foreground limit
   (or did once) starts once with `run_in_background`, and the runner waits for its completion notice;
   it never polls and never reports a foreground timeout as `partial`. `stage-5-validate.md` step 1
   says the same for an inline runner (overlays).
   Files: `agents/test-runner.md`, `skills/sdlc/templates/stage-5-validate.md`
5. **Verify.** `bash scripts/py.sh scripts/validate_skills.py`,
   `bash scripts/py.sh scripts/ci/check_contracts.py`, `bash scripts/ci/test-hooks.sh`,
   `bash scripts/ci/setup-roundtrip.sh`.
6. **Binding corrections from the sanity check** (they override steps 1–4 where they differ):
   - **Snapshot shape (step 1).** Capture once, at envelope creation, never on `--resume`:
     `git status --porcelain -z --untracked-files=all`, new path for renames (old path dirty too),
     excluding `.claude/pipeline/`. Store `data.dirty_at_start` as `{path: <git hash-object of the
     file, or "deleted">}` so a later step can tell "still the other session's edit" from "this run
     changed it too". `data.live_envelopes` is informational only (a crashed run stays
     `in_progress`); nothing gates on it.
   - **One filter point (step 2).** After the single-agent write or after 2c converge, drop each
     `dirty_at_start` path whose current hash still equals the recorded one; keep a changed one with
     `shared: true`. Name `stage-2c-converge.md` for the decomposed path. The `git diff` fallbacks in
     `changed-files-gate.md` and `stage-5.9-cleanup.md` also subtract `dirty_at_start`. Stage 6 builds
     its file list and suggested `git add` from the filtered `files_changed`, not from
     `git diff --stat`. Stage 5.7 does not read `files_changed` today: pass the filtered list to each
     lens prompt as its scope.
   - **plan-refs (step 2).** `scripts/plan-refs.sh scan` reads `git diff <base>` plus every untracked
     file, so the other session's files become this run's fix-loop failures. Add an
     `--exclude-file <file>` option (one path per line) and pass `dirty_at_start`'s unchanged paths
     from `stage-5-validate.md`. Add a regression case wherever `plan-refs.sh` is tested today.
   - **Every TASKS.md writer (step 3).** Under `writer: "orchestrator"`: the scope gate records the
     taken rows' unique substrings in `data.tasks.resolved[]` instead of marking `[~]`
     (`scope-gate.md`); Stage 0 cases 2–5 mark nothing; an ad-hoc input creates no row (its would-be
     row goes to `tasks_report.add`, and the envelope takes the derived slug); `bug-triage.md`'s
     `_manual_` row, `changed-files-gate.md`'s soft-stop debt row and `convention-grounding.md`'s
     doc-drift row go to `add`; `action-items-reassess.md` tags and Stage 6's `waves --write` are
     skipped. Stage 6 builds `tasks_report.close` with
     `close-tasks.sh close --scope resolved --ids-file <file> --dry-run` (works for every input shape),
     writes `tasks_report` before `handoff.json`, and records `data.tasks.writer` in `run.json`.
     `/sdlc-status --reconcile` will report the run's rows as open until the orchestrator applies the
     report; say so in the hand-off line.
   - **Long gates (step 4).** A one-shot test-runner cannot wait across turns on its own background
     job. So: the test-runner reports a command that hit its foreground timeout as layer status
     `deferred` with the command (replacing the "Timeout or hang → failed" bullet, not adding a
     second rule). The orchestrator then runs that command once with `run_in_background`, output to
     `.claude/pipeline/<slug>/agent-reports/<layer>.log`, waits for the completion notice, and
     dispatches the test-runner again to read that log only. Keep the agent's `model:` and `tools:`
     untouched. The Copilot/Codex note (run long suites to completion; never report a tool timeout as
     a result) goes in their overlay `SKILL.md`, not in the shared template.
   - Docs: `docs/CONFIG.md` "which stage reads it" entry for `pipeline.tasks.writer`
     (read at Stage 0 and Stage 6). Never edit the pinned GIT guard sentence in any brief.
   Files (added): `skills/sdlc/templates/scope-gate.md`, `skills/sdlc/templates/bug-triage.md`,
   `skills/sdlc/templates/changed-files-gate.md`, `skills/sdlc/templates/convention-grounding.md`,
   `skills/sdlc/templates/action-items-reassess.md`, `skills/sdlc/templates/stage-2c-converge.md`,
   `scripts/plan-refs.sh` (+ its tests)

### Cross-Module Touchpoints
- `/sdlc-status` reads `status` only; the new fields are additive.
- `scripts/close-tasks.sh rows` already exists and is read-only; no script change.
- `next-action.sh` / `stop-gate.sh` read `status` and `.next-action`; unaffected.

### Open Questions
- None. safe-commit is dropped and the work board stays repo-local (DECISIONS.md).

### Appendix: Alternatives Considered
- **safe-commit helper (parent step 7).** Dropped per DECISIONS.md: a git-write path in a skill whose
  contract is no git writes.
- **Upstream the work board.** Deferred: only one repo needs it so far.
- **Fail the run when another envelope is live.** Rejected: two sessions on disjoint files is the
  normal case; excluding their files is enough.
