# Plans — run each with `/sdlc docs/plans/<file>.md`

`plans/` is gitignored on this plugin repo (it is a consumer-side directory), so the plans
that ship with the repo live here. `/sdlc` takes any `.md` path; skill-repo mode is
auto-detected from `.claude-plugin/marketplace.json`, so Stage 3 skips and Stage 5 runs
the skill-repo validation (validator, marketplace, template refs, dry install).

Run in this order — each is sized for one session and one reviewable diff:

| # | Plan | What it buys | Run cost |
|---|---|---|---|
| 1 | `skill-evals-1-contract-checks.md` | Free static checks that catch the whole class of bug found in the 2026-09 review (phantom config keys, dangling citations, wrong-fact phrases, collapsed rename pairs). CI on every push. | Low — scripts only |
| 2 | `toolkit-steals.md` | The four items borrowed from coleam00/skills that fit without a new skill: rules-drift check in `/repo-health`, opt-in tests-must-pass Stop hook, Stage 7 plan-divergence line, and a hook regression test that also covers `enforce-model-cap.sh`. | Low–medium |
| 3 | `skill-evals-2-fixture-harness.md` | Headless outcome evals for the file-producing skills on a tiny fixture repo, with a per-case cost baseline. Nightly/manual, not per push. | Medium — each eval run spends real tokens |

Suggested invocation: `/sdlc docs/plans/skill-evals-1-contract-checks.md` with the default
`cap: sonnet`. Review stage optional; if enabled, `agents.code_review_max_lenses: 1`.

Follow-ups deliberately **not** planned yet (write a plan when 1–3 have landed):
trigger evals per skill (skill-creator's `run_eval.py`, ~20 queries × 3 runs), and
CLAUDE.md ablation (Cole's `ablate-ai-layer` method: full vs stripped rules on the fixture,
graded per rule, blind).
