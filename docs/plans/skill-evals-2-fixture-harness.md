## Brainstorm Result: Skill evals tier 2 — headless outcome evals on a fixture repo

### Direction
Give the file-producing skills a real test: a tiny fixture repo, a Python harness that
installs the toolkit into a temp copy, runs one skill headlessly with `claude -p`, and grades
the resulting tree with deterministic assertions. Every case records `total_cost_usd` from
the CLI's JSON result, so the same run doubles as a cost-regression test — the check that
would have flagged the $22 run. No LLM graders: every assertion is a file, git, or
transcript check. Runs nightly or on demand, never per push.

### Conventions & reuse
- Reuse: `scripts/eval-runner.py`'s fixture/expected/meta layout and its structured JSON
  output shape — the skill harness is a sibling runner, not a fork of it.
- Reuse: `bash setup.sh --target <tmp> --tools claude --no-hooks` to install into the
  fixture exactly as a consumer would.
- Reuse: `scripts/token-audit.py`'s tier ranking (`haiku < sonnet < opus`) for the
  cap assertion.
- Follow: `claude -p … --output-format stream-json --permission-mode bypassPermissions
  --max-turns N --max-budget-usd X` (verify the exact flag names against `claude --help` on
  the machine running it; `--max-budget-usd` is documented on the Claude Code costs page).
- New (justified): `evals/skills/` because `evals/` is the directory name the toolkit
  already reserves for evals in consumer repos; a `skills/` subtree keeps them apart.

### Implementation Steps
1. Create the fixture at `evals/skills/fixtures/mini-fastapi/`: `app.py` (FastAPI, two
   routes), `tests/test_app.py` (three passing pytest tests), `requirements.txt`
   (`fastapi`, `httpx`, `pytest`), `AGENTS.md` (10 lines), `TASKS.md` from
   `templates/TASKS.md.template`, `plans/two-step.md` (a plan in the
   `skills/brainstorm/templates/plan.md.template` shape whose two Implementation Steps
   are: add `GET /health` returning `{"ok": true}`; add a test for it), and
   `.claude/project.json` with `test.unit: "pytest -q"`, `models.cap: "sonnet"`,
   `pipeline.output.verbosity: "quiet"`, `pipeline.review_fix.enabled: false`.
2. Create `evals/skills/cases/*.json`, one per case, shape
   `{name, prompt, max_turns, max_budget_usd, assertions: [{type, ...}]}`:
   - `task-health-endpoint`: `/task add a GET /health endpoint returning {"ok": true}` →
     `tasks_row_added` (exactly one new row), `glob_exists plans/tasks/task-*-*.md`,
     `pytest_green`, `git_head_unchanged`.
   - `sdlc-two-step`: `/sdlc plans/two-step.md` → `json_path .claude/pipeline/two-step/
     run.json status in [complete, completed]`, `json_path stage-outputs/parse.json
     data.implementation_step_count == 2`, `json_path stage-outputs/handoff.json committed
     == false`, `git_head_unchanged`, `pytest_green`, `agent_models_within_cap sonnet`.
   - `sdlc-status-readout`: `/sdlc-status` → `output_max_lines 8`, `output_contains
     "Next:"`, `tree_unchanged`.
   - `plan-html-render`: `/plan-html plans/two-step.md` → `glob_exists *.html`,
     `file_not_matches <html> "https?://|<script src="`, `file_matches <html> "<style"`.
   - `repo-onboarding-keys`: `/repo-onboarding` on a copy with `.claude/project.json`
     removed → `json_keys_subset .claude/project.json templates/project.json.example`,
     `file_exists AGENTS.md`.
   - `gotcha-dedup`: run `/gotcha "pytest needs PYTHONPATH=. here"` twice →
     `count_occurrences GOTCHAS.md "PYTHONPATH=." == 1`.
3. Create `scripts/ci/skill-eval.py` (stdlib only): for each selected case copy the
   fixture to a temp dir, `git init` + one baseline commit, run `setup.sh` into it, run
   `claude -p` with cwd = temp dir, stream events to
   `evals/skills/results/<UTC-date>/<case>/events.jsonl`, pull `total_cost_usd`,
   `num_turns`, `duration_ms` from the final `result` event, then evaluate assertions.
   Implement the assertion types named in step 2 as small functions; `agent_models_within_cap`
   scans `tool_use` blocks named `Agent` and fails on any `input.model` ranking above the cap
   or missing when `subagent_type` is not a pinned agent. Write
   `results/<date>/summary.json` and `summary.md` (one row per case: pass/fail per
   assertion, cost, turns, seconds). Flags: `--case <name>`, `--all`, `--keep-tmp`,
   `--update-baseline`.
4. Cost baseline: `evals/skills/baseline.json` maps case → `total_cost_usd`; a run fails
   when a case exceeds 2× its baseline (message names the case and both numbers).
   `--update-baseline` rewrites it from the current run. Commit the first baseline.
5. CI: `.github/workflows/skill-evals.yml` on `workflow_dispatch` and a weekly cron,
   using the same `CLAUDE_CODE_OAUTH_TOKEN` secret `claude.yml` already uses; uploads
   `evals/skills/results/` as an artifact. Not attached to pull requests.
6. Docs: `docs/EVALS.md` (what the tiers are, how to add a case, how to read the summary,
   why no LLM graders yet); README "Scripts" bullet; replace the first sentence of
   `CLAUDE.md` / `AGENTS.md` "Testing changes" ("There is no automated test suite for the
   skills themselves") with a pointer to the three tiers.

### Cross-Module Touchpoints
- Plan 1's contract checks should treat `evals/skills/fixtures/**` as out of scope (it is
  a consumer repo, not toolkit prose).
- `.gitignore`: add `evals/skills/results/` except `summary.md` of the latest run if
  desired; keep `baseline.json` tracked.

### Acceptance criteria
- `python3 scripts/ci/skill-eval.py --case sdlc-status-readout` must pass locally and cost
  under $0.25.
- `--all` must pass on this branch with every assertion green; total cost under $8 with
  `cap: sonnet` and the review stage off (record the actual figure in `baseline.json`).
- The `sdlc-two-step` case must prove no git write happened: HEAD unchanged and
  `handoff.json.committed == false`.
- Deliberately breaking one assertion (e.g. expect 3 steps) must make the run exit 1 and
  name the case and assertion (verify, then revert).
- The harness itself must be stdlib-only and must never write outside the temp dir and
  `evals/skills/results/`.

### Open Questions
- Headless auth in CI: OAuth token (subscription) or an API key? The OAuth secret already
  exists for `claude.yml`; confirm it works with `-p` before wiring the cron.
- Should `sdlc-two-step` also run once with the review stage on, `max_lenses: 1`, as an
  Axis 2 smoke test? Recommend a separate, manual-only case to keep the nightly cheap.

### Appendix: Alternatives Considered
- LLM-graded rubric evals for `/brainstorm` and `/flowsim` — deferred: `/flowsim`'s core
  assertion (every anchor is a real `file:line`) is deterministic and can be added as a
  case later; `/brainstorm` is conversational and needs a human review loop.
- Trigger evals via skill-creator's `run_eval.py` — deferred to its own plan.
- Reusing the user's `claude-headless-fastapi` repo as the fixture — rejected: the
  fixture must be tiny, committed, and identical on every machine.
