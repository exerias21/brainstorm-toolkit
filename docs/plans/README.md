# Plans — run each with `/sdlc docs/plans/<file>.md`

`plans/` is gitignored on this plugin repo (it is a consumer-side directory), so the plans
that ship with the repo live here. `/sdlc` takes any `.md` path; skill-repo mode is
auto-detected from `.claude-plugin/marketplace.json`, so Stage 3 skips and Stage 5 runs
the skill-repo validation (validator, marketplace, template refs, dry install).

Run in this order — each is sized for one session and one reviewable diff:

| # | Plan | What it buys | Run cost | Status |
|---|---|---|---|---|
| 1 | `skill-evals-1-contract-checks.md` | Free static checks that catch the whole class of bug found in the 2026-09 review (phantom config keys, dangling citations, wrong-fact phrases, collapsed rename pairs). CI on every push. | Low — scripts only | |
| 2 | `toolkit-steals.md` | The four items borrowed from coleam00/skills that fit without a new skill: rules-drift check in `/repo-health`, opt-in tests-must-pass Stop hook, Stage 7 plan-divergence line, and a hook regression test that also covers `enforce-model-cap.sh`. | Low–medium | |
| 3 | `skill-evals-2-fixture-harness.md` | Headless outcome evals for the file-producing skills on a tiny fixture repo, with a per-case cost baseline. Nightly/manual, not per push. | Medium — each eval run spends real tokens | |
| 4 | `ai-native-sdlc-additions.md` | The four practices from Anthropic's AI-native SDLC playbook that this repo lacks, cut to ~20% of their designed size by an adversarial pass: the skill-vs-hook doctrine, a test-immutability **detector** (not a preventer), persisting the run-cost numbers `run-cost-report.sh` currently discards, and a smoke eval gate. Also repairs four shipping defects found while designing it — `skill-eval.py` has no `--max-budget-usd`, `load_baseline()` is dead so the cost guard has never fired, the `tasks-closeout` case asserts rows that do not exist, and `close-tasks.sh` ships but sits outside `SHIPPED_GLOBS`. | Phase 1 free (local only); Phase 2 ~$2/PR | |
| 5 | `windows-portability-and-hygiene.md` | Two shipping bugs that make the toolkit partly non-functional on Windows — `hooks/hooks.json` spawns `.sh` with no interpreter so every plugin-installed hook is dead, and 14 bare `python3` sites hit the Store stub (one of them `project.json.example`, which ships the trap to every onboarded repo). Adds a seventh `check_contracts.py` check so the class cannot recur, plus backlog hygiene: closes RUN-DURABILITY on evidence and fixes two close-out/destination gaps. | Low — no model spend | |
| 6 | `board-json-export.md` | A read-only `close-tasks.sh board` subcommand exporting `TASKS.md` + pipeline-envelope state as one JSON object, for a cross-machine/dashboard consumer with no new store. | Low — no model spend | ✓ delivered |
| 7 | `dogfood-followups.md` | Lint/contract-check fixes plus skill-repo fixes found dogfooding the toolkit on itself: `_manual_`/`_followup_` row tags, a phase-aware `reconcile`, and the `/brainstorm`/`/flowsim` skill-repo plan location (`docs/plans/`) and its knock-ons. | Low — no model spend | ✓ delivered |
| 8 | `flow-gap-fixes.md` | Closes gaps the flow axis (`/flowsim`, Stage 5's flow check) found between plan claims and shipped behavior. | Low — no model spend | |
| 9 | `subagent-git-guard.md` | Guards against a dispatched sub-agent making a git write the orchestrator didn't ask for. | Low — no model spend | ✓ delivered |
| 10 | `tasks-md-closeout.md` | `close-tasks.sh`'s first CI coverage and a row-lookup subcommand `/sdlc` Stage 0 calls instead of grepping. | Low — no model spend | |
| 11 | `stage-5.9-cleanup-pass.md` | The `/sdlc` Stage 5.9 cleanup-pass contract. | Low — no model spend | |
| — | `jev-integration.md` | Planned integration with TypeSafe's Jev models — status page, not yet implemented. | N/A | |

Suggested invocation: `/sdlc docs/plans/skill-evals-1-contract-checks.md` with the default
`cap: sonnet`. Review stage optional; if enabled, `agents.code_review_max_lenses: 1`.

Follow-ups deliberately **not** planned yet (write a plan when 1–3 have landed):
trigger evals per skill (skill-creator's `run_eval.py`, ~20 queries × 3 runs), and
CLAUDE.md ablation (Cole's `ablate-ai-layer` method: full vs stripped rules on the fixture,
graded per rule, blind).
