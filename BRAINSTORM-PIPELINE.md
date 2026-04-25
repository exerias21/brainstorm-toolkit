# Brainstorm: Toward a Production-Grade Pipeline

**Date:** 2026-04-24
**Method:** 5-agent parallel review (Skill expert, Agent expert, Code Architect, Project Manager, SDLC Expert)
**Goals:**
1. Evaluate alignment with a Jenkins-style pipeline: **BRD → PBIs → human approval → code agent → human review → PR → deploy**, with eval loops, plan-vs-delivered verification, and targeted runs (`--pbi N`, `--sonar <issue>`).
2. Identify enhancements that produce production-ready code without wasting tokens.

---

## TL;DR

The repo already contains **roughly 60% of a Jenkins-style pipeline** — `/sdlc` is the working backbone, `flowsim`/`ux-plan-validator` cover plan-vs-delivered, eval-harness implements a bounded fix loop, and cost-tier model selection (Haiku/Sonnet/Opus) is already explicit. The missing 40% is **not more skills**, it is:

1. A durable, resumable **pipeline state envelope** (`.claude/pipeline/<slug>/run.json`) that survives session boundaries.
2. **Upstream stages**: BRD intake and PBI decomposition (today the pipeline starts at a hand-authored plan).
3. **Downstream stages**: deploy, monitor, rollback (today the pipeline ends at PR creation).
4. **Approval gates** as machine-readable artifacts (today only the GitHub PR gate exists).
5. **Traceability**: a BRD requirement ID cannot be traced to a delivered line of code.
6. **Targeted runs**: `/sdlc --pbi N` and `/sdlc --sonar <key>` need a target resolver at Stage 1.

All five agents independently converged on the **state envelope** as the single highest-leverage change. Build that first; everything else slots in as new stages against the same contract.

---

## Current state — what exists today

| Pipeline stage | Skill / script | Quality |
|---|---|---|
| BRD ingestion | *(none — `/brainstorm` starts from a seed idea, not a finished BRD)* | Gap |
| PBI decomposition | *(none — `/task` creates one row at a time)* | Gap |
| Plan sanity-check | `/sdlc` Stage 1.5 (3 parallel Haiku agents) | Strong |
| Implementation | `/sdlc` Stage 2 (Opus) | Strong |
| Unit / e2e tests | `/test-check`, `/e2e-loop`, `agents/e2e-test-runner.md` | Strong |
| Eval (with fix loop) | `/eval-harness`, `scripts/eval-runner.py` | Strong but binary scoring |
| Plan-vs-delivered | `/flowsim` + `ux-plan-validator` (Stage 5.5 / 5.6) | **Best-in-class for this repo** |
| Pre-merge hygiene | `/dead-code-review` (6 parallel Opus — expensive) | Strong but costly |
| PR creation | `/sdlc` Stage 6 (`gh pr create`) | Strong |
| Deploy | *(none)* | Gap |
| Monitor / rollback | `scripts/check_docker_logs.py` for local only | Partial |
| Approval gates | GitHub PR review only | Gap (gates 1, 2, 3, 5 absent) |
| Status / dashboard | `/status` (38 lines, single-task view) | Minimal |

**Architectural shape today:** the toolkit is a *prompt distribution system with a shared file contract* (`AGENTS.md`, `TASKS.md`, `GOTCHAS.md`, `.claude/project.json`). It is not yet an orchestrator — `/sdlc` chains stages within one Claude session, but if that session drops between Stage 3 and Stage 5, all eval/fix-loop work is lost.

---

## Target architecture: the pipeline as a state machine

### The single contract every stage should obey

```
input:   .claude/pipeline/<slug>/run.json  (current stage, args, prior outputs)
output:  .claude/pipeline/<slug>/stage-outputs/<stage>.json
              { "status": "pass | fail | paused", "summary": "...", "data": {...} }
side-effect: update run.json.stage to next stage on pass
idempotency: skip if stage-output already exists with status: pass
```

This is **8 lines of JSON per stage**. Both Claude (Agent tool) and Copilot (file read) can consume it. It is the missing "stage interface" that turns a chained prompt into a resumable, restartable pipeline.

### Proposed `.claude/pipeline/` layout

```
.claude/pipeline/<feature-slug>/
  run.json                 # current stage, status, args, timestamps
  brd.md                   # source BRD (new upstream stage)
  pbis.json                # decomposed PBIs with stable IDs + acceptance criteria
  approval.json            # append-only approval audit log
  context-cache.json       # shared repo context — read once, reused by sub-agents
  stage-outputs/
    sanity-check.json
    impl-summary.json
    eval-results.json
    flowsim.json           # mirror of plans/flowsim-<slug>.json
    validation.json
    scorecard.json         # PBI-level scorecard (new)
    pr.json
    deploy.json            # new — post-merge health-check result
```

### Mapped against the user's target flow

```
BRD --[/brd-ingest]--> brd.md
brd.md --[/pbi-decompose]--> pbis.json + plans/tasks/PBI-N-*.md
                                    |
                              [APPROVAL GATE 1: PM approves PBI list]
                                    |
                                    v
                          /sdlc --pbi PBI-N (target resolver)
                                    |
                              [APPROVAL GATE 2: tech lead approves plan, optional]
                                    |
                              implement -> eval -> fix-loop -> validate -> flowsim
                                    |
                              [APPROVAL GATE 3: PR review — exists today]
                                    |
                                    v
                          /deploy (new) -> /monitor (new) -> /rollback (new)
                                    |
                              [APPROVAL GATE 4: release manager — for prod]
                                    |
                                    v
                          /coverage (BRD-level scorecard)
```

---

## Top gaps, ranked by leverage

| # | Gap | Blast radius | Smallest fix |
|---|---|---|---|
| 1 | **No resumable pipeline state** — session crash = full restart | Total | Add `run.json` + `stage-outputs/*.json` contract; add `--resume` flag to `/sdlc` |
| 2 | **No BRD or PBI artifact type** — pipeline starts at a hand-authored plan | High (PM-blocking) | New `/brd-ingest` and `/pbi-decompose` skills; new `requirements/` and `pbis/` directories with stable IDs |
| 3 | **No approval-gate machinery** — only GitHub PR review is real | High (audit-blocking) | `approval.json` audit log + `--approve-pbis` / `--require-human-review` flags on `/sdlc` |
| 4 | **No targeted-run support** — `/sdlc` requires a plan path, not a PBI ID | High (UX-blocking for incremental work) | Target resolver at Stage 1: `--pbi N` (reads `pbis.json`) and `--sonar <key>` (fetches issue, generates one-step plan) |
| 5 | **No traceability** — cannot trace a delivered line back to a BRD requirement | Medium | Add `parent_pbi` / `brd_refs` frontmatter to plans; commit convention `feat(PBI-37): ...`; PR body lists requirement IDs |
| 6 | **No deploy / monitor / rollback** — pipeline ends at PR | Medium | New stages reading `project.json.deploy.*` and `project.json.health.*`; integrate with `gh workflow run` rather than Jenkins-specific calls |
| 7 | **Eval scoring is binary** — `passed/total` with no flake tolerance, coverage delta, or perf baseline | Medium | Add `eval.thresholds` to `project.json` (`min_pass_rate`, `max_flake_retries`, `min_coverage_delta`); enforce in `eval-runner.py` |
| 8 | **No BRD-coverage rollup** — `/status` is single-task scoped | Medium (PM dashboard gap) | New `/coverage` skill that joins `requirements/`, `pbis/`, and `stage-outputs/` into a red/green matrix |
| 9 | **`skills/sdlc/SKILL.md` is 565 lines** — the only skill above the 250-line ceiling defined in `CLAUDE.md` | Low but visible | Move inline agent prompts (Stage 1.5, 5.5, 5.6) into `templates/` per repo rule 4 |
| 10 | **No worktree isolation** — every agent mutates the same working tree | Low today, blocks future PBI-parallel fan-out | Use `EnterWorktree` for parallel implementer agents once multi-PBI runs are introduced |
| 11 | **No security/secrets gate** — Stage 6 commits without a secret scan | Low frequency, high impact when it hits | Run `gitleaks` (or a regex sweep) before `git add` in Stage 6 |
| 12 | **`eval-runner.py --fix-loop` is a no-op** — explicitly stderrs "not implemented" | Low | Either remove the flag or document that the loop lives in `/sdlc`, not the script |

---

## Token-economy wins (ordered by ROI)

1. **Shared context-cache file written once per pipeline run.** Every Stage 1.5, 5.5, and e2e sub-agent currently re-reads `README.md`, `CLAUDE.md`, `GOTCHAS.md` independently (`agents/e2e-test-runner.md:36-43`, `ux-plan-validator.md:15-19`). On a 300-line `AGENTS.md`, four Stage 5.5 agents waste ~1200 lines re-reading the same content. Fix: orchestrator writes `.claude/pipeline/<slug>/context-cache.json` at Stage 1; sub-agents consume the cache, not the raw files. **Estimated saving: 40–60% of sub-agent context on large plans.**
2. **Compact JSON stage outputs replace prose summaries in context.** Stage 2 inlines the entire plan into the implementation agent's prompt (`skills/sdlc/SKILL.md:152-173`). Stage 5.5 spawns four agents each reading the full plan. Fix: emit a `plan-index.json` (`{files, steps_count, acceptance_criteria, slug}`) at Stage 1 and pass *only the index* to sub-agents that need metadata.
3. **Conditional Stage 5.5 fan-out.** Stage 5.5 spawns 4 Sonnet/Haiku validators unconditionally. Gate each agent on plan content — if the plan touches no UI, skip the UI validator. Drives Small-complexity runs (single-file SonarQube fixes) to a fraction of current cost.
4. **Tier `dead-code-review` model selection.** Forces Opus 4.6 across 6 parallel agents (`skills/dead-code-review/SKILL.md:123`). Tier it: Haiku for scripts/docs, Sonnet for backend/frontend, Opus only for the cross-module reasoning agent. Worst single-skill cost offender for a per-PR pipeline.
5. **Short-circuit `/flowsim` MATCH hops on subsequent runs.** Currently traces every flow to max-hops even when the first hop is MATCH (`skills/flowsim/SKILL.md:46-58`).

### Token spend that's *worth it*

- **Coverage diff for changed lines.** Cheap second eval-runner pass; high signal.
- **Property-based fuzzing on new pure functions** (one Sonnet call in Stage 3). Catches edges evals miss.
- **Migration round-trip test.** If plan touches DB, generate up+down migration test before merge. Massive production-safety win for one Sonnet call.

---

## Goal #2: Standalone enhancements (ship without rebuilding the pipeline)

The Jenkins-style pipeline (Goal #1) is a multi-week rebuild. **Goal #2 is independent** — these enhancements harden token efficiency and production-readiness *today*, without waiting for Phase 1's state envelope. They are ranked by ROI (impact / effort).

### Tier A — quick wins, ship this week

| # | Enhancement | Effort | Impact | Where |
|---|---|---|---|---|
| A1 | **Tier `/dead-code-review` model selection** — Haiku for scripts/docs (Agents 4–5), Sonnet for backend/frontend (1–2), Opus only for cross-module dependency reasoning (Agent 3) | ~30 min | Single largest cost reduction in the toolkit | `skills/dead-code-review/SKILL.md:121-123` |
| A2 | **Fix or remove `eval-runner.py --fix-loop` no-op** — explicitly stderrs "not implemented", misleads anyone reading `--help` | ~15 min | Removes a footgun | `scripts/eval-runner.py:325-328` |
| A3 | **Add `gitleaks` (or regex sweep) before Stage 6 `git add`** — currently zero secret-scan before commit | ~1 hr | Production-safety gate that's currently missing | `skills/sdlc/SKILL.md:472` |
| A4 | **Move `/sdlc`'s 565 lines of inline content into `templates/`** — violates the repo's own 250-line ceiling (`CLAUDE.md` rule 3); every invocation re-reads all 565 lines | ~2 hr | Reduces every `/sdlc` invocation's prompt cost; makes the skill maintainable | `skills/sdlc/SKILL.md:299-389` (Stage 5.5/5.6 inline agent prompts) |
| A5 | **Short-circuit `/flowsim` MATCH hops on subsequent runs** — currently traces every flow to max-hops even when first hop is MATCH | ~1 hr | Cuts flowsim cost on stable code paths by ~50% | `skills/flowsim/SKILL.md:46-58` |
| A6 | **Conditional Stage 5.5 fan-out** — gate each of the 4 validators on plan content (skip UI validator if plan touches no UI files) | ~2 hr | Drives Small-complexity runs (single-file fixes, SonarQube targets) to a fraction of current cost | `skills/sdlc/SKILL.md:316-389` |

### Tier B — REVISED 2026-04-25

> **The original Tier B below has been superseded** by a dogfooded `/brainstorm`
> session. Original B1/B2/B5/B6 were generic code-repo hygiene applied wholesale
> to a skills repo; the Inversion lens flagged ~70% as cargo-cult. See the
> tracked design doc: [`docs/TIER-B-REVISION.md`](docs/TIER-B-REVISION.md)
> (lifted from the dogfooded `plans/brainstorm-tier-b-revision.md` —
> `plans/` is intentionally gitignored as consumer-side output, so the
> design content lives in `docs/` instead).
>
> The revised Tier B has two tracks:
>
> - **Track 1 — Toolkit-self**: B1' overlay-parity check, B2' template-ref
>   linter, B3' setup.sh CI smoke, B4' cycle-time/blocked-reason in TASKS.md,
>   B5' pre-tool poka-yoke for secrets (Claude consumers; Copilot relies on
>   Stage 6 gitleaks).
> - **Track 2 — Consumer-pipeline (eval-runner)**: B6' eval thresholds,
>   B7' numeric tolerance + ignored-fields. Plugin-resident, so changes flow
>   to every consumer without re-running setup.
>
> First-Principles "Pre-Merge Reality Check" (replay the change against prod
> traffic in a disposable replica) is parked as a long-term north star — too
> heavy for Tier B.

### Tier B — original draft (SUPERSEDED, kept for reference)

| # | Enhancement | Effort | Impact | Where |
|---|---|---|---|---|
| B1 | **Eval thresholds in `project.json`** — `eval.min_pass_rate`, `eval.max_flake_retries`, `eval.min_coverage_delta`. Today eval scoring is binary (`passed/total`); SKIP counts as success | ~1 day | Flake tolerance + coverage gate without a full pipeline rebuild | `scripts/eval-runner.py:230` |
| B2 | **Coverage diff for changed lines** — second eval-runner pass reporting uncovered new lines | ~1 day | High-signal production gate; cheap to compute | `scripts/eval-runner.py` (new layer) |
| B3 | **Migration round-trip test** — if plan touches DB, generate up+down migration test before merge | ~1 day | One Sonnet call, large production-safety win | New stage in `/sdlc` between Stage 4 and 5 |
| B4 | **Property-based fuzzing for new pure functions** — auto-generate hypothesis tests in Stage 3 | ~2 days | Catches edge cases evals miss | `skills/sdlc/SKILL.md` Stage 3 |
| B5 | **Numeric tolerance + ignored-fields config in `eval-runner.py:diff_json`** — exact-match diff flags any nondeterministic output (timestamps, IDs, ordering) | ~half day | Production code routinely has nondeterministic outputs | `scripts/eval-runner.py:180` |
| B6 | **Pytest collection cache + `--lf` reuse** — eval-runner re-collects all tests every iteration | ~half day | Speeds up the inner fix-loop | `scripts/eval-runner.py:67` |
| B7 | **Cycle-time and blocked-reason fields in TASKS.md rows** — checkboxes have no timestamps, blocked rows have no structured reason | ~half day | Unblocks a real `/status` dashboard | `templates/TASKS.md.template` |

### Tier C — deferred until Phase 1 lands

These enhancements depend on the state envelope (Goal #1 Phase 1) and are not standalone:

- **Shared `context-cache.json`** — needs `.claude/pipeline/<slug>/` to live in. **(40–60% sub-agent context savings.)**
- **PBI-level scorecard** — needs `pbis.json` from Phase 2.
- **Worktree-isolated parallel implementers** — needs run state to coordinate non-overlapping file claims.
- **`--resume` flag** — needs `run.json`.

### Production-readiness bar (the merge gate)

What every generated change should clear before merge. Each row maps to existing tooling or a Tier A/B enhancement above:

| Bar | Status today | Closes with |
|---|---|---|
| All unit tests pass, including new ones | Covered (`/test-check`) | — |
| Plan requirements satisfied | Covered (Stage 5.5 + `/flowsim`) | — |
| No new log errors at runtime | Covered locally (`check_docker_logs.py`) | — |
| No new HIGH/CRITICAL findings | Covered | — |
| **No secrets in commit** | **Missing** | A3 |
| **Coverage of changed lines ≥ threshold** | **Missing** | B2 |
| **No test flake masking failure** | **Missing** | B1 |
| **Numeric/list-order tolerance in eval diff** | **Missing** | B5 |
| **Migration up+down round-trip works** | **Missing** | B3 |
| Performance regression budget | Missing | (deferred — needs baseline storage) |
| PR with reviewable diff | Covered (Stage 6) | — |

Shipping Tier A (this week) + B1/B2/B3 (this month) closes 5 of the 6 missing gates. That is "production-ready merge gate" without touching the pipeline architecture.

### One-pass vs iterative — per-stage recommendation

The SDLC expert's audit, useful as a sanity-check on any future stage:

| Stage | Mode | Why |
|---|---|---|
| Plan parse / sanity-check | One pass | Cheap Haiku; iteration adds noise |
| Implementation | One pass | Iterating without feedback regresses; rely on eval loop downstream |
| Eval | Iterate (max 3) | Already correct in `--max-fix-loops` |
| `/test-check` unit/frontend | One pass + targeted fix | Failures route to Stage 4 fix loop |
| E2E | Iterate w/ flake guard | Already correct in `e2e-loop` |
| Plan-vs-delivered (5.5/5.6) | Iterate | Mismatches need re-trace after fix |
| PR creation | One pass | Idempotent; retry only on transport error |
| Deploy verify (proposed) | Iterate w/ exponential backoff | Health checks are inherently polled |
| Rollback (proposed) | One pass | Must be deterministic and fast |

---

## Tier A Implementation Plan (in flight)

Six Tier A enhancements organized into three phases. Phase order is hygiene → token efficiency → production safety so each phase edits cleaner code than the last.

### Phase 1 — Hygiene (low risk, mechanical cleanup)

- [x] **A2** — Remove `--fix-loop` no-op from `scripts/eval-runner.py` (lines 325–328). The fix loop lives in `/sdlc` Stage 4; the script flag is misleading.
- [x] **A4** — Move `/sdlc`'s inline agent prompts (Stage 1.5, 5.5, 5.6) into `templates/`. The skill is 565 lines; the repo's own ceiling (`CLAUDE.md` rule 3) is 250. **Done: 565 → 397 lines (–30%); 4 templates extracted to `skills/sdlc/templates/`. Further reduction would require restructuring stage logic, deferred.**

### Phase 2 — Token efficiency (cost reduction, no behavior change)

- [x] **A1** — Tier `/dead-code-review` model selection: Haiku for scripts/docs (Agents 4–5), Sonnet for backend/frontend (1–2), Opus only for the cross-module reasoning agent (Agent 3). Currently all 6 are Opus. **Done: per-agent model annotations added; rule updated to allow per-run promotion of a single agent if needed.**
- [x] **A5** — Short-circuit `/flowsim` MATCH hops on subsequent runs. Currently traces every flow to max-hops even when the first hop matches. **Done: new step 0 reads `plans/flowsim-<slug>.json` cache, marks all-MATCH flows whose anchor files are unchanged as `cached-MATCH` and skips re-tracing. `--force` flag bypasses the cache.**
- [x] **A6** — Conditional Stage 5.5 fan-out in `/sdlc`: gate each of the 4 validators (api/ui/data/cross-module) on plan content rather than spawning all 4 unconditionally. **Done: gating table added before the fan-out; `cross-module` always runs, others gated on plan content (file paths, schema mentions, route mentions).**

### Phase 3 — Production safety (new merge gate)

- [x] **A3** — Add `gitleaks` (or regex-based) secret scan before Stage 6 `git add`. Currently zero secret-scan before commit. **Done: new pre-commit step in Stage 6; prefers `gitleaks` if installed, falls back to a curated regex sweep (AWS, OpenSSH, Slack, sk-/ghp_/gho_ tokens, generic key/secret/token assignments). HIGH/CRITICAL findings block; MEDIUM warns. Opt-out via `pipeline.skip_secret_scan: true` (added to `templates/project.json.example`).**

---



The agents converged on this sequence — each phase is independently shippable and unblocks the next.

### Phase 1 — Pipeline state envelope (foundation; ~1 week)

- Add `.claude/pipeline/<slug>/run.json` schema + `stage-outputs/` convention.
- Add `--resume` flag to `/sdlc`; each stage checks for its own output and skips if `status: pass`.
- Refactor `/sdlc` Stages 1.5, 2, 4, 5, 5.5, 5.6 to write JSON sidecars alongside their existing prose.
- Add a `pipeline.*` namespace to `project.json` with graceful-skip semantics; document in `templates/project.json.example`.

**Unlocks:** resumability, targeted runs, traceability, all downstream phases.

### Phase 2 — Upstream: BRD and PBIs (~1 week)

- New `/brd-ingest` skill: parse a BRD doc → `requirements/BRD-<id>.md` with stable `REQ-NNN` IDs.
- New `/pbi-decompose` skill: BRD → `pbis.json` + per-PBI plan stubs in `plans/tasks/PBI-N-*.md` with `brd_refs: [REQ-001, REQ-014]` frontmatter. **Vetting is default-on** for this skill (testability + traceability + coverage agents per PBI batch — see `skills/post-deploy-verify/SKILL.md` "Companion: BRD → PBI vetting (forward-looking contract)" for the required agent set and CRITICAL-flag semantics). Unlike `/brainstorm`'s `--vet` flag (opt-in), BRD → PBI vetting cannot be disabled — bad PBIs multiply harm across the pipeline.
- Extend task frontmatter with `pbi`, `parent_pbi`, `requirement_id`.
- Adopt commit convention `feat(PBI-37): ...`; auto-include requirement IDs in PR body.

**Unlocks:** traceability matrix, BRD-level coverage rollup.

### Phase 3 — Targeted runs (~3 days)

- `/sdlc --pbi N` resolver: reads `pbis.json`, synthesizes plan, runs pipeline scoped to that PBI.
- `/sdlc --sonar <issue-key>`: new `sonar.*` block in `project.json`; fetches issue, generates one-step plan.
- Unify all pipeline-stage skills on a `--target {pbi-id|sonar-key|jira-key|file:line}` arg.

**Unlocks:** the user's stated "target a specific PBI / SonarQube issue" workflow.

### Phase 4 — Approval gates (~3 days)

- Append-only `approval.json` audit log (gate, approved_by, at, note).
- Flags: `--approve-pbis`, `--require-human-review` (post-implement, pre-eval).
- New `/approve` skill that flips state and writes the audit row.

**Unlocks:** non-engineer stakeholder trust; auditability.

### Phase 5 — Plan-vs-delivered scorecard (~3 days)

- Extend Stage 5.5 to emit `scorecard.json` per PBI with weighted score (eval_pass 0.4 + flowsim_match 0.3 + ac_grep 0.2 + file_present 0.1).
- Block PR if any PBI scores < 0.6 OR any acceptance criterion has zero eval coverage.

**Unlocks:** the "did we actually build what the BRD asked for" question.

### Phase 6 — Downstream: deploy / monitor / rollback (~1 week)

- New `/deploy` skill reading `project.json.deploy.*`; emits manifest, calls `gh workflow run`.
- New `/monitor` skill polling `health.url`; feeds failures back into `TASKS.md` as new PBIs.
- New `/rollback` skill (`gh workflow run rollback.yml --ref <sha>`).
- New `/coverage` skill: BRD-coverage red/green matrix joining `requirements/`, `pbis/`, `delivery/`.

**Unlocks:** end-to-end Jenkins-style flow.

### Phase 7 — Token-economy hardening (~3 days)

- Shared `context-cache.json` at Stage 1; sub-agents read cache, not raw repo files.
- Conditional Stage 5.5 fan-out gated on plan content.
- Tier `/dead-code-review` model selection (Haiku/Sonnet/Opus per agent role).
- Move `/sdlc`'s 565 lines of inline templates into `templates/`.

**Unlocks:** sustainable cost on a per-PR pipeline.

---

## CI integration boundary (important)

**Skills emit a manifest; CI consumes it.** Skills should NOT shell out to Jenkins or GitHub Actions directly — that couples the agent layer to a CI vendor and creates auth/secret leakage risk.

- Stage 6 already calls `gh pr create` — that's an acceptable hard dependency.
- Add `plans/sdlc-manifest-<slug>.json` listing `feature_slug`, `files_changed`, `evals_added`, `eval_results`, `flowsim_status`, `scorecard`, `requirement_ids`.
- CI reads it via `actions/checkout` + `jq`, runs its own gates (deploy, smoke, security scan), and posts back via PR comment.
- **Agent layer owns *what was promised*. CI owns *what runs in production*.**

---

## Open decisions for the user

These shape the next phase. None can be settled by the agents alone.

1. **State location: `.claude/pipeline/` (proposed) vs. extending `TASKS.md`?** The architect strongly favors `.claude/pipeline/` to keep `TASKS.md` human-readable. PM agreed. Confirm before Phase 1.
2. **Approval gate UX: file-edit (manual) vs. dedicated `/approve` slash command vs. GitHub-comment-driven?** All three have trade-offs. The slash command is most consistent with the repo's existing pattern.
3. **Do we want PBI-parallel fan-out (worktree-isolated implementers running multiple PBIs concurrently) in v1, or defer to v2?** Adds complexity (worktrees) but is a force multiplier for large BRDs.
4. **SonarQube auth: env-var-only, or do we add a `sonar.token_command` indirection (e.g., `op read op://...`)?** The latter is more secure but adds a config knob.
5. **Should `/dead-code-review` run on every PR, or only on a `chore/cleanup` cadence?** It's the most expensive skill in the toolkit; per-PR is overkill for most changes.

---

## Appendix — agent reports

This synthesis is drawn from five parallel agent reviews:
- **Skill Expert** — pipeline-stage map of every existing skill, gap list, "target PBI/Sonar" feasibility.
- **Agent Expert** — sub-agent inventory, orchestration patterns, hand-off contract recommendation, cost concerns.
- **Code Architect** — system shape, state model, stage interface, approval gates, top architectural risks, token-economy proposals.
- **Project Manager** — BRD→PBI flow gaps, traceability matrix design, approval gate locations, status reporting needs, plan-vs-delivered design, targeted re-run UX.
- **SDLC Expert** — coverage table, eval-loop failure modes, production-readiness bar, CI integration boundary, one-pass-vs-iterative recommendation per stage.
