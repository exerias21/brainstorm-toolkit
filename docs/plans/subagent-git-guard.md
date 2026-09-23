## Brainstorm Result: Sub-agent git-write guard (+ flowsim cache pointer)

> Source: the 2026-09-19 skill-mining review of that day's session transcripts
> (`E:\programming\jev\reports\skill-review-2026-09-19.md`, candidates c5 and c4). Both were
> kept by a skeptic pass that re-checked the transcript evidence and the live skill files.

### Direction

**Fix 1 (this plan): tell every dispatched sub-agent that may edit files not to write to git.**
On 2026-09-19 in poc-contractor, an `/sdlc` implement sub-agent ran `git stash` on its own
initiative, next to uncommitted Phase 1 work. The orchestrator then had to check by hand that
nothing was lost (`stash list` empty, files still modified). `/sdlc` promises "no git writes at
all" (`skills/sdlc/SKILL.md:7, 348`), but that promise lives in the *orchestrator's* skill text.
**None of the prompts that dispatch sub-agents say it.** `stage-2-implement.md` and
`stage-2b-dispatch.md` only tell the agent to run `git diff --stat` (`:41`, `:53`). The fix is
one canonical guard sentence, inserted verbatim into each dispatch prompt and pinned by the
existing contract check, so deleting it fails CI.

**Fix 2 (already planned; do not duplicate): `/flowsim` writes the cache its step 0 reads.**
Step 0 (`skills/flowsim/SKILL.md:38-56`) reads `plans/flowsim-<slug>.json`, and no step ever
writes it. This is not an architectural leftover:
- The *pipeline's* flowsim sidecar was retired on purpose (`docs/PHASE-1-STATE-ENVELOPE.md:653`).
- `skills/sdlc/templates/state-schema.md:297` still names `plans/flowsim-<slug>.json` as the
  **canonical output of the standalone skill**.

`docs/plans/dogfood-followups.md` item 12 already specifies the exact fix: write the flows array
plus `written_at`, create `plans/` if missing, and reword "Flowsim is read-only" (`:107`) to
"never edits source". It has a TASKS row, phase 3. **Run it from that plan.** This plan adds no
row for it.

Rejected for now: a deterministic backstop (a PreToolUse hook that blocks `git stash|commit|
checkout|reset…` while an envelope is `in_progress`, shaped like `enforce-model-cap.sh`). It's
real protection, but it's a new hook with parallel-hook and portability costs
(`windows-portability-and-hygiene.md`). Revisit it only if the prompt guard proves insufficient.

### Conventions & reuse

- **Follow the prompt-rule style already in these templates:** a hard rule stated once, with
  its reason. See `stage-2b-dispatch.md:38-54` ("CRITICAL RULES").
- **Follow the single-source rule for shared templates:** the Codex and Copilot overlays
  *read* `skills/sdlc/templates/stage-2-implement.md` (`codex/skills/sdlc/SKILL.md:171`,
  `copilot/skills/sdlc/SKILL.md:169`), so one edit covers all three hosts.
  `stage-2b-dispatch.md` is Claude-only ("not applicable" on the overlays, `codex/...:166`,
  `copilot/...:164`). **No overlay edits.**
- **Reuse the pin in `scripts/ci/forbidden-phrases.txt`:** an allow-glob entry `path:N` pins the
  expected occurrence count, and a count **below** the pin is a finding ("pin is stale";
  `check_contracts.py:487-536`). Pinning the guard sentence at `:1` in each dispatch template
  turns "someone deleted the guard" into a CI failure, with no new check code.
- **Follow the version-bump convention:** each plan phase ends with a plugin.json +
  marketplace.json bump row (see the Done rows for `ai-native-sdlc-additions`).
- **Out of scope:** `/task`, which legitimately commits (the `coauthor_trailer` path), and
  `stage-2c-converge.md`, which is the orchestrator's own step, not a dispatched editor.

### Implementation Steps

#### Phase 1 — Guard every file-editing sub-agent dispatch

1. **The canonical guard sentence** (verbatim, one line, identical everywhere):

   > GIT: never run a git command that writes — no stash, commit, checkout, switch, reset, restore, rebase, merge, clean, or branch creation. The working tree holds the user's uncommitted work; git that only reads (status, diff, log, show) is fine. If you need a clean baseline, report it as a blocker instead.

2. **Insert it into each prompt that dispatches a file-editing sub-agent:**
   - `skills/sdlc/templates/stage-2-implement.md`: inside the prompt block, immediately above
     "After implementation, run: git diff --stat" (`:41`).
   - `skills/sdlc/templates/stage-2b-dispatch.md`: as a bullet in "CRITICAL RULES" (`:38-54`),
     above the `git diff --stat -- {lane_files}` line (`:53`).
   - `skills/sdlc/templates/fix-loop.md`: in "The loop" (`:8-10`), the fix agent is "told to fix
     *only* those failures with no refactor". Add "and given the GIT line from
     `stage-2-implement.md` verbatim".
   - `skills/sdlc/templates/stage-5.7-review-fix.md`: where the fix agent's prompt is built
     (around `:121`), the same instruction to include the GIT line verbatim.
   - `agents/e2e-test-runner.md`: Step 5, "Dispatch fix agent" (`:133-135`), the same.

   For the three "include it verbatim" sites, prefer quoting the sentence in full over a
   cross-reference: a sub-agent never sees the orchestrator's template.
3. **Pin it** in `scripts/ci/forbidden-phrases.txt`: one row whose regex matches a unique fragment
   of the sentence (e.g. `no stash, commit, checkout, switch`). The reason is "the sub-agent
   git-write guard: pinned so removing it from a dispatch prompt fails CI". Allow-globs list each
   file from step 2 with its count (`:1`, or the real count). Also allow-glob this plan file
   (`docs/plans/subagent-git-guard.md`) at its count, **or** confirm `check_contracts.py`'s file
   set excludes `docs/plans/`. Run `bash scripts/py.sh scripts/ci/check_contracts.py` and confirm
   it's clean, then delete the line from one template and confirm it fails.
4. **Record the incident** in `GOTCHAS.md`: "Dispatched sub-agents don't inherit the
   orchestrator's no-git-writes rule — state it in every dispatch prompt". Include the
   2026-09-19 poc-contractor `git stash` as the example and point to the pinned row.
   **`GOTCHAS.md` is gitignored in this repo** (`.gitignore:22`), so that entry is local-only. The
   durable record is a short worked example in `docs/ENFORCEMENT.md` (tracked, not shipped): the
   incident, why prose in the orchestrator's skill does not reach a dispatched agent, the pinned
   row as the guard, and the deferred PreToolUse hook with its revisit trigger (a second incident).
5. **Version bump** (plugin.json + marketplace.json), the last commit of the phase.

### Cross-Module Touchpoints

- **`/test-check --loop`** dispatches through `agents/e2e-test-runner.md`, so it's covered by
  step 2.
- **`/sdlc-status`**'s "code-defect → `/task fix:`" path goes through `/task`, which commits by
  design and is intentionally not guarded.
- **Codex/Copilot:** covered through the shared `stage-2-implement.md`. Verify after the change
  by reading `codex/skills/sdlc/SKILL.md:171` and confirming it still points at the template
  rather than inlining its own prompt.

### Open Questions

- **Should `git stash` be allowed read-only-ish** (stash, run tests, pop) for "isolate
  pre-existing failures"? Recommendation: no. That's exactly the pattern that endangered the
  work, and the sentence tells the agent to report a blocker instead.
- **Is a hook-level backstop worth it?** Deferred (see Direction). The trigger for revisiting is
  any second incident after this lands.
- **Flowsim:** it's in `dogfood-followups.md` phase 3, behind the in-progress phase 2. If you'd
  rather ship it alongside this guard, move its row's `_plan:` tag here *and* update item 12 in
  that plan, so the two don't drift.

### Appendix: Alternatives Considered

- **PreToolUse hook blocking git writes during an `in_progress` envelope.** Deferred. It's the
  strongest guarantee, but it adds a hook (parallel-hook and portability cost) for a failure seen
  once.
- **Pre/post `git stash list` + `git status` snapshot comparison in the orchestrator.** Rejected.
  It detects after the fact, doesn't prevent anything, and the skeptic pass flagged it as
  over-built.
- **One cross-reference ("see the no-git rule in SKILL.md") instead of the verbatim sentence.**
  Rejected. Dispatched sub-agents don't read the orchestrator's skill.
- **A new flowsim plan.** Rejected. It would duplicate `dogfood-followups.md` item 12 and its
  existing TASKS row.
