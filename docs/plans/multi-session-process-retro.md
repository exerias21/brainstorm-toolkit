## Brainstorm Result: Multi-session process retro — upstream the generic fixes

> Written 2026-10-19 in a consumer repo (bdt-rewrite, a comp-engine rewrite) after two Claude
> sessions and about a dozen delegated /sdlc runs shared one worktree for two days. Its own plan
> (`plans/brainstorm-freedom-process-retro.md` there) runs Phases 0–4 locally; **this file is its
> Phase 5: the generic parts, carried out here, in the toolkit repo.** Nothing below is copied from
> that repo's data; examples are generalised.

### Direction

Six upstream changes (steps 16–21 of the consumer plan), plus lessons discovered while running it
(the "Discovered" section). Ship them as independent phases, smallest first, each with the usual
version bump and validator pass. Everything is opt-in or additive: repos with a single session and
no hooks must see no change in behaviour.

### Discovered while running it (2026-10-18 → 2026-10-19)

These are measured facts from the consumer repo, the reason for each step below.

1. **Delegated /sdlc runs silently degrade to "ad hoc".** Agents briefed to "run /sdlc" skipped
   Stage 1.5, wrote the code themselves instead of dispatching the implement agent, and wrote no
   pipeline envelope, while still reporting the run as /sdlc. Cause: the brief also said "don't
   re-delegate the whole task", which reads as forbidding Stage 2's separate implement agent.
   Fix direction: a delegated run must record every stage as `ran` or `skipped: <reason>` in
   `run.json`, and the hand-off must print that table; Stage 7 should fail loudly when `implement`
   has no implement-agent sidecar.
2. **Two sessions in one worktree collide in five distinct ways:**
   - **Stale-index revert:** a private-index commit (`GIT_INDEX_FILE=… read-tree HEAD; add; commit`)
     silently reverted the other session's commit that landed between `read-tree` and `commit`.
     `git commit` takes the new HEAD as parent but writes the old tree. Fix: `commit-tree -p
     <pinned H>` plus `update-ref <ref> <new> <H>` (compare-and-swap), and a check that
     `git diff --stat H new` lists only the intended paths.
   - **Empty commits:** the same helper made an empty commit when the other session had already
     committed identical text. Refuse when `git diff --quiet H T`.
   - **Swept hunks:** whole-file commits of shared single-writer files (`TASKS.md`, `HUMAN.md`,
     `DECISIONS.md`, `AGENTS.md`) carried the other session's uncommitted hunks four times in two
     days, and two rows got the same id. Locked append helpers that allocate ids remove this.
   - **The gate blocks on the other lane:** the commit gate ran the whole suite on the working
     tree, so one session's half-finished files blocked the other's commits about six times. The
     consumer repo chose a work board (each session's claimed paths, with a heartbeat) so failures
     are attributed to their owner, rather than per-session worktrees.
   - **Hooks are live for every session:** a PreToolUse hook edited mid-run changes behaviour for
     both sessions on their next call, and a crashing hook exits non-blocking (gate silently off).
     Build a replacement hook beside the live one, `node --check` it and test it, then swap it in
     one move.
3. **The commit gate's text match is wrong in both directions.**
   `/(^|[;&|\s])git(\s+-C\s+\S+)?\s+commit\b/` fires on `git commit-tree` (the `-` is a word
   boundary) and on an `echo` that merely mentions it, but not on `git update-ref` or on any
   script that commits internally. Gate real ref updates, not command text.
4. **New files are invisible to `git ls-files`-based ratchets** (a PII-literal check) until staged,
   so a literal passed the gate in a private-index commit and failed the next commit. Ratchets
   must scan the commit's own tree, untracked new files included.
5. **Agents poll.** A fix agent left ~18 `until grep -q … ; do sleep 5; done` loops behind:
   each Bash call hit its 2-minute timeout, went to the background, and the agent started
   another. Briefs must say: start a long run once (`run_in_background`) and wait for the
   completion notice; iterate on changed test files only; full suite once at the end.
6. **Agents ran Prettier over whole files** in a repo where Prettier is not the formatter,
   inflating a +38/-1 diff to +303/-57. Briefs must name the repo's formatter and "format only
   files you changed".
7. **The question advisor pays off immediately.** Its first run on three draft operator questions
   dropped two (one settled by reading the code, one already answered by earlier rulings) and
   rewrote the third in plain words with measured numbers. Only the third reached the operator.
8. **The operator wants one writer for `TASKS.md` during delegated runs** (the orchestrator), and
   `/sdlc` Stage 6's close-out assumes the agent may write it. Needs a "report rows, don't write"
   mode.
9. **Long gates exceed tool timeouts** (a 10-minute foreground limit against a ~12-minute
   offline suite). The handoff should run the final gate in the background and wait for the notice,
   not report "partial".

### Implementation Steps

#### Phase 1 — Agent-return contract and brief rules
1. `skills/sdlc/templates/output-verbosity.md`: agent-return contract. Full detail goes to a file
   under the envelope; the hand-back is at most 40 lines plus that file's path. (Consumer step 17.)
2. `pipeline.implement.must_follow` (string list in `project.json`): quoted word for word into
   `stage-2-implement.md`, `fix-loop.md` and `stage-2b-dispatch.md`. Ship built-in defaults for
   Discovered 5 and 6: one background test run, never a polling loop; the repo's formatter only,
   changed files only; never `git checkout/restore/stash/reset` in a shared tree. (Consumer step 18.)
3. Stage ledger: every stage writes `ran` or `skipped: <reason>` into `run.json`, the hand-off
   prints it, and Stage 7 flags an `implement` with no implement-agent sidecar (Discovered 1).

#### Phase 2 — Plan template sections
4. `skills/brainstorm/templates/plan.md.template`: `## Premises`, `## Baseline & exit measurement`,
   `## Pins and forward behaviour`. Stage 0 parses them and the sanity completeness focus checks
   them. (Consumer step 19: a review found exactly the forward-run pin class these would catch.)

#### Phase 3 — Question advisor and ask-gate
5. A generic `agents/question-advisor.md` (read-only, Opus): drop questions already answered by
   the decision log or ticked operator rows, measure instead of asking where a "measure first"
   source can answer, fix stale premises, sharpen the rest (plain words, measured numbers,
   recommendation first, at most 4), and write `.claude/pipeline/_advice/approved.json` with
   per-question hashes. Repo-specific data sources come from a `project.json` "measure_first"
   list. (Consumer step 16; the consumer's agent is at `.claude/agents/question-advisor.md` there.)
6. `hooks/ask-gate.js`: PreToolUse on `AskUserQuestion`, blocks questions whose hash is not in a
   fresh `approved.json` (45 min). Off switch is a **file flag**, not an env var (an env var cannot
   be set in a running session). Opt-in wiring only; an `operator-gate.md` template covers repos
   without hooks. Sub-agents never ask the operator; they return drafts to the orchestrator.

#### Phase 4 — Opt-in commit hand-off and multi-session safety
7. Opt-in `pipeline.handoff.commit: "safe-commit"` with a `stage-6b-commit.md` template, off by
   default (the no-git-write contract stays right for other repos). The helper: pinned parent,
   compare-and-swap `update-ref`, refuse paths outside the pathspec, refuse an empty tree diff,
   run the repo's gate itself (the hook does not fire inside a script), keep the repo's
   data-path refusal, and restore only the shared-index entries it changed itself. (Consumer
   step 20; Discovered 2–4.)
8. Stage 0 records `dirty_at_start` and other live envelopes; `files_changed` and the review
   scope exclude them. (Consumer step 21.)
9. Stage 6 "report rows" mode: `pipeline.tasks.writer: "orchestrator"` makes a delegated run list
   the rows to close or add instead of editing `TASKS.md` (Discovered 8).
10. Stage 5/6: run the final gate in the background and wait for the completion notice when it is
    longer than the tool timeout (Discovered 9).

### Conventions & reuse
- Version bump per phase (`.claude-plugin/plugin.json`, `marketplace.json`), validator pass, the
  skill-repo Stage 5 checks.
- Do not edit `skills/sdlc/templates/*` while another session is running /sdlc from this plugin
  root; use a `git worktree` of this repo, or land when no run is active.

### Cross-Module Touchpoints
- The consumer repo's local versions (question-advisor, ask-gate, safe-commit.sh, the work
  board) are the reference implementations; port the generic core, not the repo-specific data
  sources.

### Open Questions
- Which phases to take first. Recommendation: Phase 1 (cheapest, fixes Discovered 1, 5, 6 for
  every repo), then Phase 3.
- Whether the work board (consumer Phase 2 revision) is generic enough to upstream, or stays
  repo-local until a second repo needs it. Recommendation: repo-local for now.
