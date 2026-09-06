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
- Follow: `claude -p … --output-format stream-json --verbose --permission-mode
  bypassPermissions --max-budget-usd X`. **Flags verified against `claude --help` on
  Claude Code 2.1.261 (2026-09-05): `-p`, `--output-format stream-json`,
  `--permission-mode bypassPermissions` and `--max-budget-usd` all exist; `--max-turns`
  does NOT exist and must not be passed** — `--max-budget-usd` is the only bound, which is
  sufficient since it is a hard spend ceiling. `--output-format` works only with `--print`.
  The `result` event's field names (`total_cost_usd`, `num_turns`, `duration_ms`) are NOT
  documented in `--help`, so the harness must read them defensively (`.get()`, record
  `null` when absent) rather than KeyError on a schema change.
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
   `{name, prompt, max_budget_usd, assertions: [{type, ...}]}` (no `max_turns` — the CLI has no such flag):
   - `task-health-endpoint`: `/task add a GET /health endpoint returning {"ok": true}` →
     `tasks_row_added` (exactly one new row), `glob_exists plans/tasks/task-*-*.md`,
     `pytest_green`, `git_head_unchanged`.
   - `sdlc-two-step`: `/sdlc plans/two-step.md` → `json_path .claude/pipeline/two-step/
     run.json status == complete`
     (the state schema's only terminal success value — `completed` is not a valid status), `json_path stage-outputs/parse.json
     data.implementation_step_count == 2`, `json_path stage-outputs/handoff.json data.committed
     == false`, `git_head_unchanged`, `pytest_green`, `agent_models_within_cap sonnet`.
   - `sdlc-status-readout`: `/sdlc-status` → `output_max_lines 8`, `output_contains
     "Next:"`, `tree_unchanged`.
   - `plan-html-render`: `/plan-html plans/two-step.md` → `glob_exists *.html`,
     `file_not_matches <html> "https?://|<script src="`, `file_matches <html> "<style"`.
   - `repo-onboarding-keys`: `/repo-onboarding` on a copy with `.claude/project.json`
     removed → `json_keys_subset .claude/project.json .claude/project.json.example`
     (setup.sh installs the example to `.claude/project.json.example`; there is no
     `templates/` dir in an installed target),
     `file_exists AGENTS.md`.
   - `gotcha-dedup`: run `/gotcha "pytest needs PYTHONPATH=. here"` twice →
     `count_occurrences GOTCHAS.md "PYTHONPATH=." == 1`.
3. Create `scripts/ci/skill-eval.py` (stdlib only): for each selected case copy the
   fixture to a temp dir, `git init` + one baseline commit, run `setup.sh` into it, run
   `claude -p` with cwd = temp dir. **Isolate the child session explicitly** — it inherits
   the parent's environment, and the parent here is this repo: set `CLAUDE_PROJECT_DIR` to
   the temp dir (do not merely unset it — explicit beats implicit) so any hook the child
   runs resolves to the fixture and never to the parent repo's `.claude/`; never copy the
   user's global `~/.claude/settings.json` into the fixture; and keep `--no-hooks` on the
   install so the fixture carries no Stop hooks of its own. Then stream events to
   `evals/skills/results/<UTC-date>/<case>/events.jsonl`, pull `total_cost_usd`,
   `num_turns`, `duration_ms` from the final `result` event, then evaluate assertions.
   Implement the assertion types named in step 2 as small functions; `agent_models_within_cap`
   scans `tool_use` blocks named `Agent` and fails on any `input.model` ranking above the cap
   or missing when `subagent_type` is not a pinned agent. Write
   `results/<date>/summary.json` and `summary.md` (one row per case: pass/fail per
   assertion, cost, turns, seconds). Flags: `--case <name>`, `--all`, `--keep-tmp`,
   `--update-baseline`.
4. Cost baseline: **note what actually bounds cost here.** `--no-hooks` means the fixture
   gets no `enforce-model-cap.sh` PreToolUse hook, so `models.cap: "sonnet"` is
   prose-enforced only; the real guards are `--max-budget-usd` (hard) and the
   `agent_models_within_cap` assertion (detects a dispatch above the cap after the fact).
   The baseline is only trustworthy if that assertion is green on the recording run.
   `evals/skills/baseline.json` maps case → `total_cost_usd`; a run fails
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
- `.gitignore`: add `evals/skills/results/` **followed by a negation so the baseline stays
  tracked** — an ignore rule on the parent path would otherwise swallow it:
  ```
  evals/skills/results/
  !evals/skills/baseline.json
  ```

### Acceptance criteria
- `python scripts/ci/skill-eval.py --case sdlc-status-readout` must pass locally and cost
  under $0.60. (The original $0.25 was a guess and is wrong: a measured run cost $0.269 and
  a $0.25 ceiling ABORTS the session mid-flight with `subtype: error_max_budget_usd`, leaving
  a partial tree that grades as false skill failures. The harness now names that cause
  explicitly instead of reporting the truncation as assertion failures.)
- `--all` must pass on this branch with every assertion green; total cost under $8 with
  `cap: sonnet` and the review stage off (record the actual figure in `baseline.json`).
- The `sdlc-two-step` case must prove no git write happened: HEAD unchanged and
  `handoff.json` `data.committed == false`.
- Deliberately breaking one assertion (e.g. expect 3 steps) must make the run exit 1 and
  name the case and assertion (verify, then revert).
- Invoke it as `python` (this repo's convention: `python3` is a broken stub on the Windows dev machine; the harness must resolve an interpreter defensively, trying `python3` then `python`, as the hooks already do).
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
