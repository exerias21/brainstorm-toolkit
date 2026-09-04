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
   table with the same weighting as Check 5. Keep the check under 20 lines; the agent brief
   carries the rules.
2. **Stop gate hook** — create `scripts/hooks/stop-gate.sh`. Read stdin; locate the
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
   description; in `setup.sh` call `install_stop_hook_claude stop-gate.sh stop-gate` next
   to the run-cost-report call and add a Codex entry via the same pattern as
   `install_context_watch_codex` (Codex honors `decision:block`); Copilot: print-only, skip.
   Add `"stop_gate": "off"` and `"stop_gate_timeout": 300` with `_comment`s under
   `pipeline` in `templates/project.json.example`; extend the README hooks list by one
   bullet; one sentence in `docs/LOOP-HYGIENE.md` on the hop bound.
4. **Stage 7 divergence line** — in `skills/sdlc/SKILL.md` Stage 7 and in the Stage 7
   section of `copilot/skills/sdlc/SKILL.md` and `codex/skills/sdlc/SKILL.md`, add one
   sentence: "If the delivered diff departs from the plan (a step skipped, reordered, or
   solved differently), say where and why in one line each — `ux-plan-validator`'s
   partial/missing rows are the source." No new sidecar, no new section.
5. **Hook regression harness** — create `scripts/ci/test-hooks.sh`: builds a temp project,
   feeds sample payloads to `enforce-model-cap.sh` (the eleven cases: not enforced, opus→
   sonnet, `review:` exempt, haiku untouched, pinned agent untouched, unpinned agent
   filled, general-purpose filled, fable clamped, non-Agent tool ignored, full model id,
   malformed config) and to `stop-gate.sh` (off by default; no envelope → silent; envelope
   in_progress + green tests → silent; red tests → `decision:block`; hop budget exhausted →
   silent with systemMessage; missing command → silent). Assert with `grep -q`; exit 1 on
   the first failure. Add a CI step to `.github/workflows/setup-roundtrip.yml`.
6. Update `CLAUDE.md` / `AGENTS.md` "Testing changes" to name the hook harness, and the
   "Unified contracts" hooks sentence to list `stop-gate.sh` beside the others.

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
  the gate fast and predictable.

### Appendix: Alternatives Considered
- Port `prime-codebase` as a skill — rejected: `/repo-onboarding` plus the
  convention-grounding template already cover it.
- Port `piv-review-changes` — rejected: single-agent, no verify pass; Stage 5.7 is stronger.
- Port `system-execution-report` as a new sidecar — rejected: the envelope, Stage 7 report
  and gotcha capture already hold everything but the divergence line.
- Worktree skills — rejected: `/sdlc` does no git writes by design.
