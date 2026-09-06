# Testing this toolkit: three tiers

Skills here are prompts, not code, so there is no single test suite. Instead there are three
independent tiers, cheapest first. Each one catches a failure class the others cannot.

## Tier 0 — static prose/contract checks (free, runs on every push)

Lints the skill prose itself, without ever invoking a model:

- **`python scripts/validate_skills.py`** — frontmatter shape, name-to-directory alignment,
  Copilot-targeted skills leaking Claude-only capabilities, `agents/*.md` frontmatter
  (missing `name`/`description`, a prose model-tier or read-only claim the frontmatter
  doesn't enforce), marketplace registration drift.
- **`python scripts/ci/check_contracts.py`** (`--self-test` exercises it against a synthetic
  tree) — proves the prose and the config agree: every `project.json` key a skill names
  exists in `templates/project.json.example`, every repo-path citation resolves, no
  forbidden (rename-invalidated) phrase from `scripts/ci/forbidden-phrases.txt` survives,
  and no sentence names the same `/command` twice (the signature of a collapsed
  `s|/old|/new|g` rename). Deliberately excludes `evals/skills/fixtures/**` — that tree is a
  mock consumer repo, not toolkit prose.
- **`python scripts/ci/check_install_refs.py <installed-dir>`** — the same citation check,
  but against what a consumer actually receives after `setup.sh`, since a per-tool overlay
  installs *instead of* the canonical skill tree and can dangle a citation the repo-side
  linter never sees.
- **`bash scripts/ci/test-hooks.sh`** — regression harness for the hooks that make policy
  deterministic instead of prose-enforced (`enforce-model-cap.sh`, `stop-gate.sh`).

Runs in the `setup-roundtrip` CI workflow on every push and PR. Seconds, not dollars.

## Tier 1 — fixture-based pytest evals (`scripts/eval-runner.py`)

For a *consumer* repo's own features (not this toolkit's skills): drop fixture/expected JSON
pairs under `evals/<feature>/` and a pytest file under `tests/eval/`, and
`python scripts/eval-runner.py --feature all` runs both layers and diffs actual vs. expected
JSON. No model calls unless the feature under test makes one. See `skills/test-check/SKILL.md`
step 6 and `.claude/project.json`'s `eval.runner` key.

## Tier 2 — headless outcome evals on a fixture repo (`scripts/ci/skill-eval.py`)

The one tier that actually runs a skill. `evals/skills/fixtures/mini-fastapi/` is a tiny,
committed FastAPI app; `scripts/ci/skill-eval.py` copies it into a temp dir per case, installs
the toolkit into that copy exactly as a consumer would (`setup.sh --tools claude --no-hooks`),
runs one skill headlessly (`claude -p <prompt> --output-format stream-json --permission-mode
bypassPermissions --max-budget-usd <X>` — no `--max-turns`, that flag does not exist), and
grades the resulting tree with deterministic assertions: file/JSON/git-state checks, never an
LLM grader. Every case also records `total_cost_usd` from the CLI's result event, so the same
run doubles as a cost-regression test against `evals/skills/baseline.json` (fails a case that
exceeds 2x its recorded baseline).

**Costs real money. Never runs on push or PR** — only `workflow_dispatch` and a weekly cron
(`.github/workflows/skill-evals.yml`), using the same `CLAUDE_CODE_OAUTH_TOKEN` secret
`claude.yml` already uses.

```bash
python scripts/ci/skill-eval.py --case sdlc-status-readout   # one case, cheap
python scripts/ci/skill-eval.py --all                        # every case in evals/skills/cases/
python scripts/ci/skill-eval.py --all --update-baseline      # rewrite the cost baseline
python scripts/ci/skill-eval.py --case gotcha-dedup --keep-tmp  # inspect the temp copy after
```

### Adding a case

Drop a JSON file at `evals/skills/cases/<name>.json`:

```json
{
  "name": "<name>",
  "prompt": "/some-skill do the thing",
  "max_budget_usd": 3.0,
  "assertions": [
    { "type": "file_exists", "path": "some/output/file" }
  ]
}
```

Optional keys: `repeat` (run the same prompt N times against the same fixture copy before
asserting — used by `gotcha-dedup` to prove dedup, not duplication) and `pre_setup_remove`
(paths deleted from the fixture copy before `setup.sh` runs — used by `repo-onboarding-keys`
to simulate a repo with no `.claude/project.json` yet).

Implemented assertion types (`scripts/ci/skill-eval.py`'s `ASSERTION_FUNCS`): `tasks_row_added`,
`glob_exists`, `pytest_green`, `git_head_unchanged`, `json_path`, `output_max_lines`,
`output_contains`, `tree_unchanged`, `file_matches`, `file_not_matches`, `json_keys_subset`,
`file_exists`, `count_occurrences`, `agent_models_within_cap`. Each is a small, independent
function — read the docstring-free but short bodies in the script rather than a separate
reference; there is no template layer to keep in sync here.

### Reading the summary

Each run writes `evals/skills/results/<date>-<run-id>/summary.json` (structured) and
`summary.md` (a table: case, pass/fail, cost, turns, seconds, with each failing assertion's
message underneath). `evals/skills/results/` is gitignored; `evals/skills/baseline.json` is
the one file in that tree that stays tracked (see the `.gitignore` negation next to it).

### Child-session isolation

The harness never lets the child `claude -p` session see this repo's own `.claude/`:
`CLAUDE_PROJECT_DIR` is set explicitly to the temp fixture dir (not merely left unset), the
fixture install always passes `--no-hooks`, and the user's global `~/.claude/settings.json` is
never copied in. The harness itself writes only under the per-case temp dir and
`evals/skills/results/` — `evals/skills/baseline.json` is the sole, explicit exception, and
only under `--update-baseline`. The parent session's own `CLAUDE_*` variables are scrubbed
too: run from inside a Claude Code session, the child would otherwise inherit a live session
id, a messaging socket and an effort setting describing a different session entirely. Only
the auth vars survive.

**What isolation does NOT cover: the operator's output style.** The child still reads the
user-level setting, and there is no way to force it off — `--settings
'{"outputStyle":"default"}'` does not override user level, and isolating `CLAUDE_CONFIG_DIR`
breaks auth because credentials live there. An "explanatory"/"learning" style appends
commentary the skill never emitted, so **any assertion over free-form output must scope to a
structured artifact** or it measures the operator instead of the skill. `output_max_lines`
takes `scope: "fenced"` for exactly this: `/sdlc-status` emitted a correct 4-line fenced
readout inside a 12-line message, and a whole-message count read that as a verbosity
regression. A baseline recorded from an unscoped assertion will not reproduce on another
machine or in CI.

### When a case aborts on its budget

`--max-budget-usd` is a hard ceiling, and hitting it **truncates the session mid-flight**:
the CLI emits `subtype: error_max_budget_usd` and the tree left behind is partial. The
harness detects that and says so explicitly, because the assertion failures underneath it
are artefacts of the truncation, not skill findings — grading them would send you hunting a
bug that isn't there. Raise that case's `max_budget_usd` and re-run. Budgets live per-case in
`evals/skills/cases/*.json`; keep the worst-case sum (each budget × its `repeat`) under what
you are willing to spend on one `--all`, since a runaway case bills up to its ceiling.

### Interpreter resolution

Anything the harness or its CI wrapper shells out to that needs "a Python" resolves
defensively — `python3` first, then `python`, then `py` — the same probe
`scripts/hooks/run-cost-report.sh` uses (checking the interpreter actually *runs*, not merely
that it resolves on `PATH`: on Windows, `python3` is commonly a Microsoft Store stub that
exits non-zero). Hardcoding either name breaks somewhere — `python3` on some Windows dev
machines, `python` on some CI images that ship only `python3`.

## Why no LLM graders (yet)

Every assertion across all three tiers is a file, git, or transcript check — deterministic,
free to re-run, and immune to grader drift. `/flowsim`'s core claim (every anchor is a real
`file:line`) is deterministic too and can be added as a Tier 2 case later.
`/brainstorm`-shaped conversational skills are the harder case: judging a brainstorm's quality
needs a human review loop, not a rubric, so that's deferred rather than faked with an LLM
grader that would itself need grading.
