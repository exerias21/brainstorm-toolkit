## Brainstorm Result: Multi-session process retro, Phase 1 (agent-return contract, brief rules, stage ledger)

### Direction
Ship Phase 1 of `docs/plans/multi-session-process-retro.md` alone, in one /sdlc run at version
0.18.25. Phase 1 changes prose and config only. It adds no hook, no agent and no git write.
Three decisions were settled in a brainstorm interview (2026-10-19):
- **must_follow built-ins are always on.** Exactly two rules ship built in: Discovered 5 (one
  background test run, never a polling loop) and Discovered 6 (the repo's formatter, changed files
  only). They apply to every repo. `pipeline.implement.must_follow` in project.json extends them.
  This is a deliberate change from the parent plan's "no change for single-session repos" line:
  the brief text gains two rules, and those rules cost nothing in a single-session run. The
  shared-tree rule (never `git checkout`, `restore`, `stash` or `reset`) is not a built-in; it
  ships as an example `must_follow` entry in `templates/project.json.example`, for repos that
  share a worktree to opt into.
- **Stage 7 fails loudly, on Claude only.** On Claude, Stage 2 records proof that an implement
  agent ran: the agent id and model tier from the dispatch result, saved in `implement.json` as
  `data.dispatch`. The orchestrator writes `implement.json` itself (`skills/sdlc/SKILL.md:262`),
  so the file's existence proves nothing; only `data.dispatch` does. A Claude run with an
  `implement` stage and no `data.dispatch` (or no `implement.json`) is marked degraded, and the
  hand-off names what is missing. It is not a warning. The Copilot and Codex overlays implement
  inline by design (`copilot/skills/sdlc/SKILL.md:181`), so they are exempt from this check.
- **Degraded is a field, not a status.** `run.json.status` keeps its four values (`in_progress`,
  `complete`, `failed`, `paused`; `skills/sdlc/templates/state-schema.md:90`), because
  `/sdlc-status` and the stop hooks branch on it. Degraded is recorded as additive
  `data.degraded: {"reason": "...", "missing": "..."}` next to whichever status the run ends with.
- **The stage ledger extends what exists.** `run.json` already has `stages_completed` and
  `stages_skipped` (`state-schema.md:91-92`); the missing part is why a stage was skipped. Add
  additive `data.skip_reasons: {"<stage>": "<reason>"}`, with one entry for every name in
  `stages_skipped`. `stages_skipped` stays a string array, so existing completed runs stay
  readable and no migration is needed.

### Conventions & reuse
- Follow: stage bodies live in `skills/sdlc/templates/`, and the SKILL.md gate points at them. Edit the
  template, then the Copilot and Codex overlays. See AGENTS.md "Where the canonical stage prose lives".
- Follow: `project.json` keys must be listed in `templates/project.json.example`, or
  `scripts/ci/check_contracts.py` fails. Covers `pipeline.implement.must_follow`.
- Follow: state fields are documented in `skills/sdlc/templates/state-schema.md`. Add the ledger keys
  there.
- Reuse: the Stage 7 report at `skills/sdlc/SKILL.md:329` (`## Stage 7 — Report`) is the place for the
  sidecar check and the ledger table.
- Doc drift: none found. `stage-2b-dispatch.md` is cited by the parent plan but must be checked when
  edited.

### Implementation Steps

#### Phase 1 — Agent-return contract, brief rules, stage ledger
1. **Agent-return contract.** There is no hand-back rule today (`output-verbosity.md` covers only the
   orchestrator's own narration), so this step ADDS one. Source of truth: a new section in
   `output-verbosity.md`. Full detail goes to a file under the run's envelope
   (`.claude/pipeline/<slug>/agent-reports/<role>.md`), and the hand-back is at most 40 lines plus
   that file's path. Each dispatch brief that returns prose (implement, 2b lane, fix-loop) gets a
   one-line pointer to the rule; JSON-only returns (sanity focuses, 2a decompose) are already short
   and unchanged.
   Files: `skills/sdlc/templates/output-verbosity.md`, the three briefs from step 2,
   `copilot/skills/sdlc/SKILL.md`, `codex/skills/sdlc/SKILL.md` (only if they restate the rule).
2. **must_follow.** Add `pipeline.implement.must_follow` (string list). Ship exactly two built-in rules,
   always on: one background test run and never a polling loop; the repo's formatter on changed files
   only. Quote the built-ins and every configured entry word for word into the three briefs. In
   `templates/project.json.example`, show the shared-tree rule ("never `git checkout`, `restore`,
   `stash` or `reset` in a shared tree") as an example entry; it is opt-in, not built in.
   Keep each brief's existing `GIT: never run a git command that writes — no stash, commit,
   checkout, switch, …` guard sentence word for word (it is pinned by the forbidden-phrases check
   and is always on); the must_follow block sits next to it and never replaces it. The example's
   `_comment` says the briefs already carry a git-write guard and the entry shows the syntax for
   a repo-specific rule. Never name a bare `python`/`python3` in a built-in or example
   (`bash scripts/py.sh` per GOTCHAS). Add a `_comment` sibling per the example file's style, and a
   line in `docs/CONFIG.md` if it lists `pipeline.*` keys.
   Files: `skills/sdlc/templates/stage-2-implement.md`, `skills/sdlc/templates/fix-loop.md`,
   `skills/sdlc/templates/stage-2b-dispatch.md`, `templates/project.json.example`, plus the
   Copilot and Codex overlays where they carry brief text.
3. **Stage ledger and degrade check.**
   - Every append to `stages_skipped` also writes `data.skip_reasons[<stage>]`. The append sites are
     `skills/sdlc/SKILL.md` (Stage 3 skill-repo row, Stage 5.7, Stage 5.9),
     `stage-5.7-review-fix.md` (review / review-fix self-skip), `stage-5.9-cleanup.md` (cleanup),
     `stage-6-handoff.md` (implement skipped on a validation-only run), and the matching sites in
     both overlays. State the rule once in `state-schema.md` and add the reason at each site. The
     Stage 7 report (in `SKILL.md`) prints one table: each stage as `ran` (from
     `stages_completed`) or `skipped: <reason>`.
   - On Claude, Stage 2's state write saves the dispatch result's agent id and model tier as
     `implement.json` `data.dispatch`. For a decomposed run, `stage-2b-dispatch.md` records each
     lane's agent id and tier, and `converge.json` carries them as `data.dispatch` (one entry per
     lane).
   - Stage 7 (Claude only) sets `data.degraded` and prints it at the top of the report when the run has
     `implement` in `stages_completed` and its Stage 2 sidecar (`implement.json`, or `converge.json` when
     `data.stage2_decomposed: true`) missing or lacking `data.dispatch`. It names what is
     missing. `status` is not changed. Copilot and Codex skip this check.
   Files: `skills/sdlc/SKILL.md` (Stage 2 state write, Stage 7 section),
   `skills/sdlc/templates/state-schema.md` (`data.skip_reasons`, `data.dispatch`, `data.degraded`),
   `skills/sdlc/templates/stage-6-handoff.md`, `skills/sdlc/templates/stage-2c-converge.md`,
   `skills/sdlc/templates/stage-2b-dispatch.md`, `skills/sdlc/templates/stage-5.7-review-fix.md`,
   `skills/sdlc/templates/stage-5.9-cleanup.md`. The degrade check never loads
   `stage-5.7-review-fix.md`. In
   `copilot/skills/sdlc/SKILL.md` and `codex/skills/sdlc/SKILL.md`, add the skip-reason write only,
   not the degrade check.
4. **Version and contracts.** Bump `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` to 0.18.25.
   Run `python scripts/validate_skills.py`, `python scripts/ci/check_contracts.py`, and
   `bash scripts/ci/test-hooks.sh`. The ledger is prose-plus-state, so no hook changes. Edit the
   two version strings by hand, never a repo-wide substitution. Check line endings with
   `git ls-files --eol` (sub-agents can introduce CRLF). Record the three decided Open Questions
   below (advisor model, ask-gate language, safe-commit dropped) with `scripts/record-decision.sh`
   at Stage 6.
   Files: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

### Cross-Module Touchpoints
- Overlays: `copilot/skills/sdlc/SKILL.md` and `codex/skills/sdlc/SKILL.md` must not drift from the
  canonical gate. `validate_skills.py` soft-warns on drift.
- Shell install: no hook or repo-root path changes, so `scripts/sync-global.sh` needs no edit.
- Consumers: repos that run delegated agents get the two built-in rules on their next install.
- Parent plan: Phases 2 to 4 stay as written in `docs/plans/multi-session-process-retro.md`. Phase 3
  (question-advisor) needs the decisions below first.

### Open Questions
- **Advisor model (Phase 3, decided):** `models.question_advisor`, default Sonnet, no cap exemption.
  Record it in DECISIONS.md and in the Phase 3 plan before that run.
- **ask-gate language (Phase 3, decided):** shell in `scripts/hooks/`, not `hooks/ask-gate.js`. Record it in DECISIONS.md.
- **safe-commit (Phase 4, decided):** dropped from the plan for now. Keep the no-git-writes contract.
  Record the decision in DECISIONS.md.
- **Work board (Phase 4, open):** the parent plan recommends repo-local. Not needed until Phase 4.
- **Limit of the degrade check (known, accepted):** it catches an orchestrator that writes the code itself
  inside a run. It cannot catch a delegated run that writes no envelope at all, which was the other half
  of Discovered 1. That needs the parent orchestrator to check the child run's envelope, which is
  Phase 4's ledger work.

### Appendix: Alternatives Considered
- **Whole plan in one run.** Rejected: Phases 3 and 4 need design decisions that the interview has
  now settled, but none of them has been recorded yet.
- **Phases 1 and 2 together.** Rejected for this run: Stage 0 parsing and the sanity checks change, which
  makes the run larger. Phase 2 comes next.
- **must_follow opt-in only.** Rejected: each repo would have to learn the Discovered 5 and 6 failures
  again before it got the fix.
- **Stage 7 as a warning.** Rejected: it would allow the silent degrade in Discovered 1 to happen again.
- **Versioned ledger schema.** Rejected: it needs a migration path for the 18 existing runs in
  `.claude/pipeline/`. Measured 2026-10-19: 18 run directories plus `HANDOFF.md`.
- **`degraded` as a fifth `run.json.status` value.** Rejected: `/sdlc-status` and the stop hooks branch
  on `status`, so a new value is not additive. Use the `data.degraded` field instead.
- **Treat the presence of `implement.json` as proof of delegation.** Rejected: the orchestrator writes
  that file (`skills/sdlc/SKILL.md:262`), so an orchestrator that implemented inline still writes it.
  Only the dispatch result's agent id is evidence.
- **Degrade check on every runtime.** Rejected: the Copilot and Codex overlays implement inline by
  design (`copilot/skills/sdlc/SKILL.md:181`), so every run there would be flagged.
- **The shared-tree git rule as a third built-in.** Rejected for this run: the interview decided on two
  built-ins. It ships as an example `must_follow` entry instead.
- **ask-gate as `hooks/ask-gate.js`.** Rejected: it breaks the shell hook convention and needs its own
  test and parity wiring.
- **safe-commit as an opt-in helper.** Deferred: it is a git-write path in a skill whose contract is
  no git writes, and it needs its own decision first.
