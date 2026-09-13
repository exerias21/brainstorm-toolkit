## Brainstorm Result: Borrow four items from coleam00/skills without adding a skill

### Direction
Four pieces of Cole Medin's AI-layer toolkit fit this repo and none needs a new skill:
(1) a rules-drift check as a new `/repo-health` check, (2) an opt-in tests-must-pass Stop
hook that only fires while an `/sdlc` run is in progress, (3) a one-line plan-divergence
entry in the `/sdlc` Stage 7 report, and (4) a hook regression harness in CI that covers the
new hook and the existing `enforce-model-cap.sh`. Everything else in his set overlaps
`/sdlc`, `/brainstorm`, `/repo-onboarding` or conflicts with the no-git-writes contract.

### Conventions & reuse
- Follow: `skills/repo-health/SKILL.md` Check 8/9 shape (scope guard → dispatch or
  procedural step → capped structured result → `skip` reason when the surface is absent).
- Follow: `scripts/hooks/run-cost-report.sh` for the envelope scan (fires only when a
  `.claude/pipeline/*/run.json` matches a status) and its jq-or-python fallback.
- Follow: `scripts/hooks/next-action.sh` for the Stop-hook `{"decision":"block","reason":…}`
  contract and its hop-counter file pattern (`.claude/.auto-continue-hops`).
- Reuse: `setup.sh` `install_stop_hook_claude <script> <label>` and
  `install_stop_hook_codex` to wire the new hook; `hooks/hooks.json` for the plugin route.
- Reuse: the eleven-payload test pattern used to exercise `enforce-model-cap.sh` (temp
  project dir, `CLAUDE_PROJECT_DIR`, sample stdin JSON, assert on stdout).
- Doc drift: `CLAUDE.md` "Testing changes" says there is no automated test suite for the
  skills; after this plan the hooks have one.

### Implementation Steps
1. **Rules drift check** — add `### Check 10 — Rules drift (Sonnet agent)` to
   `skills/repo-health/SKILL.md` after Check 9. Scope guard: skip with reason
   `no AGENTS.md/CLAUDE.md` when neither exists, or `no diff` when
   `git diff --name-only <main_branch>...HEAD` is empty (fall back to the last 20 commits
   on `main_branch` itself). Dispatch one agent, Sonnet by default per
   `skills/sdlc/templates/models.md`, print the `model:` line, with the brief: read the
   rules file and the changed-file list; for every rule or "where things live" pointer that
   the change makes false, emit a **Fix** row with the minimal edit; for a new durable
   invariant the change establishes, emit at most three **Add** rows of one line each;
   list what was checked and is still true. Cap 10 findings. Add the check to the Roll-up
   with the same weighting as Check 5 — note the Roll-up is a **scoring formula**, not a
   weighted table (Check 5 appears as `3*stale_gotchas`), so add a term at weight 3 AND add a
   10th row to the example report block. Keep the check under 20 lines; the agent brief
   carries the rules.
2. **Stop gate hook** — create `scripts/hooks/stop-gate.sh`. Read stdin.
   **First, two mandatory stand-downs, before any other work** (Stop hooks run in
   **parallel** and `hooks.json` order does NOT establish precedence, so a second
   simultaneous `decision:block` is undocumented behaviour — the gate must guarantee by
   construction that it is the only blocker):
   (a) if the stdin JSON's `stop_hook_active` is `true`, exit 0 immediately — this is the
   documented escape hatch against an infinite block loop, and Claude Code overrides a Stop
   hook after 8 consecutive blocks anyway (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`);
   (b) if a pending `.claude/.next-action` sentinel exists, exit 0 and print a
   `systemMessage` saying the gate stood down for the seam — `next-action.sh` owns the block
   in that event. Then locate the
   project as `run-cost-report.sh` does; exit 0 unless `.claude/project.json` has
   `pipeline.stop_gate: "tests"` **and** some `.claude/pipeline/*/run.json` has
   `status: "in_progress"` **and** `test.unit` is set. Read hop count from
   `.claude/.stop-gate-hops` (default 0); if it is ≥ `pipeline.loop.max_hops` (default 5),
   exit 0 and print a `systemMessage` saying the gate stood down. Run `test.unit` with
   `timeout ${pipeline.stop_gate_timeout:-300}`; on exit 0 delete the hop file and exit 0;
   on failure increment the hop file and print
   `{"decision":"block","reason":"stop-gate: tests red — <last 15 lines, 1200 chars max>"}`.
   Never block when the command is missing (`command not found` → `systemMessage`, exit 0).
   Mirror the header comment style of the other hooks.
3. **Wire the hook** — add it to `hooks/hooks.json` Stop array with a one-sentence
   description (position is documentation only — Stop hooks fire in parallel, so the
   stand-downs in step 2, not array order, are what keep a single blocker); in `setup.sh` call `install_stop_hook_claude stop-gate.sh stop-gate` next
   to the run-cost-report call and add a Codex entry via the same pattern as
   `install_context_watch_codex` (Codex honors `decision:block`); Copilot: print-only, skip.
   Add `"stop_gate": "off"` and `"stop_gate_timeout": 300` with `_comment`s under
   `pipeline` in `templates/project.json.example`; extend the README hooks list by one
   bullet; one sentence in `docs/LOOP-HYGIENE.md` on the hop bound, and a short
   `docs/SEAM.md` subsection stating the single-blocker contract: Stop hooks run in
   parallel, so exactly one hook may block per event; `next-action.sh` holds that right
   whenever a sentinel is pending and `stop-gate.sh` stands down for it.
4. **Stage 7 divergence line** — in `skills/sdlc/SKILL.md` Stage 7 and in the Stage 7
   section of `copilot/skills/sdlc/SKILL.md` and `codex/skills/sdlc/SKILL.md`, add one
   sentence: "If the delivered diff departs from the plan (a step skipped, reordered, or
   solved differently), say where and why in one line each — the `plan-conformance-validator`'s
   partial/missing rows are the source." No new sidecar, no new section.
5. **Hook regression harness** — create `scripts/ci/test-hooks.sh`: builds a temp project,
   feeds sample payloads to `enforce-model-cap.sh` (the eleven cases: not enforced, opus→
   sonnet, `review:` exempt, haiku untouched, pinned agent untouched, unpinned agent
   filled, general-purpose filled, fable clamped, non-Agent tool ignored, full model id,
   malformed config) and to `stop-gate.sh` (off by default; no envelope → silent; envelope
   in_progress + green tests → silent; red tests → `decision:block`; hop budget exhausted →
   silent with systemMessage; missing command → silent; **`stop_hook_active: true` → silent
   even with red tests**; **a pending `.claude/.next-action` sentinel → silent even with red
   tests**, the two-blocker contention case). Assert with `grep -q`; exit 1 on
   the first failure. Add a CI step to `.github/workflows/setup-roundtrip.yml`.
6. Update `CLAUDE.md` **and** `AGENTS.md` (they must stay byte-identical — verify with
   `cmp`). In "Testing changes", insert the hook harness as a **new step 3, immediately after
   the existing `scripts/ci/check_contracts.py` step**, renumbering the current 3–5 to 4–6;
   do not append it at the end and do not clobber the `check_contracts.py` step, which landed
   after this plan was written. Also update the "Unified contracts" hooks sentence to list
   `stop-gate.sh` beside the others.

### Cross-Module Touchpoints
- `/repo-health` Roll-up scoring gains a row; `README.md` skills table description for
  `/repo-health` should mention rules drift.
- `setup.sh`, `hooks/hooks.json`, `templates/project.json.example` change together — the
  contract checks from plan 1 (if landed first) will flag any key named but not added.

### Acceptance criteria
- `bash scripts/ci/test-hooks.sh` must exit 0 with every case reported `ok`.
- With `pipeline.stop_gate` absent, `stop-gate.sh` must produce no output for any input
  (verify in the harness).
- With the gate on and a failing `test.unit`, the hook must emit valid JSON whose
  `decision` is `block`, and after `max_hops` consecutive failures it must stand down.
- `python3 scripts/validate_skills.py` and `bash scripts/ci/setup-roundtrip.sh` pass; a
  fresh `setup.sh --tools all` install shows the Stop array with three Claude entries.
- `skills/repo-health/SKILL.md` grows by no more than 20 lines; `skills/sdlc/SKILL.md` by
  no more than 3.
- No skill or template loses an existing instruction (diff review).

### Open Questions
- Should the stop gate also honour `test.frontend`? Recommend no in v1; one command keeps
  the gate fast and predictable. (`test.frontend` does exist in
  `templates/project.json.example`, so this is a deliberate omission, not an oversight.)

### Resolved during sanity-check (2026-09-05)
- *What happens when two Stop hooks both emit `decision:block`?* **Undocumented.** Stop hooks
  run in **parallel** and array order does not establish precedence, so the plan's original
  "add it next to the run-cost-report call" bought no ordering guarantee. Resolved by
  construction rather than by relying on harness behaviour: step 2 gives `stop-gate.sh` two
  stand-downs (`stop_hook_active`, and a pending seam sentinel) so exactly one hook can block
  per event. Step 5 tests both.

### Appendix: Alternatives Considered
- Port `prime-codebase` as a skill — rejected: `/repo-onboarding` plus the
  convention-grounding template already cover it.
- Port `piv-review-changes` — rejected: single-agent, no verify pass; Stage 5.7 is stronger.
- Port `system-execution-report` as a new sidecar — rejected: the envelope, Stage 7 report
  and gotcha capture already hold everything but the divergence line.
- Worktree skills — rejected: `/sdlc` does no git writes by design.
