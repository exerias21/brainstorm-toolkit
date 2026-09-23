# Config contract: `.claude/project.json`

> **✓ Live contract — current and maintained.**

Every key is optional. Skills skip a step gracefully when its key is missing, so a repo with
no `project.json` at all still gets useful behavior from `/brainstorm`, `/task` and `/gotcha`.
Split out of `README.md` so the front page stays a tour rather than a reference.

Start from [`templates/project.json.example`](../templates/project.json.example), which
carries an inline comment for every key. `/repo-onboarding` writes this file for you.

This page mirrors `templates/project.json.example`; that file is the registry
`scripts/ci/check_contracts.py` validates against — update it first.

`.claude/project.json`, all keys optional (`_comment` keys below are stripped for readability
— the real file's inline comments are more detailed than this page):

```json
{
  "test": {
    "unit": "pytest tests/ -v --tb=short",
    "frontend": "cd web && pnpm test --run",
    "e2e": "npx playwright test --reporter=json",
    "e2e_max_fix_loops": 3,
    "e2e_patterns_file": ".claude/e2e-patterns.md",
    "e2e_rerun_failed_only": true
  },
  "logs": {
    "command": "docker compose logs {service} --tail={tail}",
    "services": ["api", "web", "worker"]
  },
  "stack": {
    "up": "docker compose up -d --build",
    "rebuild": "docker compose up -d --build --force-recreate",
    "url": "http://localhost:3000"
  },
  "eval": {
    "runner": "bash scripts/py.sh scripts/eval-runner.py",
    "features_dir": "evals/",
    "thresholds": {
      "min_pass_rate": 0.85
    }
  },
  "python": "python3",
  "gotchas_file": "GOTCHAS.md",
  "main_branch": "main",
  "coauthor_trailer": false,
  "modules": ["api", "web", "worker"],
  "models": {
    "cap": "sonnet",
    "sanity": null,
    "code_review": "opus",
    "code_review_second_pass": "sonnet"
  },
  "agents": {
    "sanity_focuses": ["paths", "completeness", "gotchas"],
    "code_review_lenses": ["correctness", "plan-alignment", "config-env-docs", "security"],
    "code_review_max_lenses": 4,
    "code_review_passes": 1,
    "code_review_max_fix_loops": 3,
    "decompose_min_tasks": 6,
    "decompose_min_files": 12,
    "cleanup_lenses": ["over-engineering", "docstring-currency"],
    "cleanup_max_lenses": 2
  },
  "migrations": {
    "dir": "backend/migrations",
    "applied_check": "psql \"$DATABASE_URL\" -tAc \"select max(version) from schema_migrations\""
  },
  "discipline": {
    "staleness_hours": 24,
    "frontend_globs": ["**/*.tsx", "**/*.jsx", "**/*.vue", "**/*.svelte", "**/*.css", "**/*.scss"],
    "backend_globs": ["**/*.py", "**/*.go", "**/*.rb", "**/*.java", "**/*.ts"],
    "data_globs": ["**/migrations/**", "**/schema/**", "**/models/**", "**/*.sql"],
    "docs_globs": ["**/*.md", "docs/**"],
    "deploy_delta_globs": ["requirements.txt", "pyproject.toml", "poetry.lock", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "go.mod", "Cargo.toml", "Gemfile.lock", "Dockerfile", "**/Dockerfile"],
    "memory_index": null
  },
  "pipeline": {
    "skip_secret_scan": false,
    "poka_yoke": false,
    "enforce_cap": false,
    "stop_gate": "off",
    "stop_gate_timeout": 300,
    "scope": {
      "max_steps_per_run": 8
    },
    "output": {
      "verbosity": "quiet"
    },
    "context": {
      "cost_report": "on"
    },
    "review_fix": {
      "enabled": false,
      "mode": "interactive"
    },
    "cleanup": {
      "enabled": false,
      "mode": "interactive"
    },
    "loop": {
      "max_items": 5,
      "batch_size": 5,
      "max_hops": 5,
      "auto_continue": false
    }
  }
}
```

`coauthor_trailer` decides whether a commit message this toolkit writes or suggests ends with
`Co-Authored-By: Claude <noreply@anthropic.com>`. It is **`false` unless you opt in:** attribution is a disclosure choice rather than a default, and some DCO / commit-lint setups
reject unrecognized trailers. `/repo-onboarding` asks the question outright rather than
guessing, and never infers consent from trailers already in `git log`. Only two surfaces read
it, because they are the only two that touch commit text: `/task`, on the runs where you asked
it to commit, and `/sdlc`'s Stage 6 hand-off, which *prints* a suggested commit and never runs
one.

**Every model and agent-count knob lives in `models` and `agents`.** Full contract:
`skills/sdlc/templates/models.md`.

There are **two independent axes**, and conflating them is the classic mistake:

| | Axis 1: the fan-out ladder | Axis 2: the adversarial reviewer |
|---|---|---|
| Keys | `models.cap`, `models.sanity` | `models.code_review`, `.code_review_second_pass` |
| Values | `haiku` \| `sonnet` \| `opus` | `haiku` \| `sonnet` \| `opus` \| `fable` |
| Capped? | yes, everything passes through the cap | **never** |

`models.cap` is a **ceiling**, not a setting: `effective = min(stage_tier, cap)`. So
`sonnet` lowers every Opus dispatch while leaving Haiku agents alone: you cut Opus spend
without upgrading the cheap ones. Per-run override `--model <tier>` (precedence: flag >
`models.cap` > default) wins both directions. **The fan-out is Sonnet-first by default:**
out of the box `/sdlc` and `/brainstorm --vet ultra` run their fan-outs on Sonnet; `--model opus` is the deliberate opt-up.

**The consequence worth knowing:** because the cap only *lowers*, a stage whose built-in
tier is `haiku` cannot be raised by `models.cap` or `--model` at all. The per-stage key is
the only lever, which is why `models.sanity` exists. It governs the **sanity check, which is
Stage 1.5** (Stage 1 is plan parsing, which dispatches nothing; that is why the shorthand
above starts at "sanity"). Stage 1.5 is never gated, so it runs on every single run.

`agents.*` sets **how many** agents each fan-out stage dispatches. Cost scales roughly
linearly: one agent (or reviewer call) per entry, so trimming
`agents.code_review_lenses` to `["correctness", "security"]` roughly halves the review
stage. All of it governs sub-agents only, never the session orchestrator.

`pipeline.scope.max_steps_per_run` bounds Stage 0's scope gate for a plan-file `/sdlc` run
(default `8`) — the fallback step-count cut used only when the plan has no `#### Phase N`
headers to cut on instead. Task id / range / ad-hoc / `--queue` inputs never pass through this
gate; `--no-scope-gate` forces whole-plan execution for a single run without touching the config.

`pipeline.loop.*` tunes the backlog loop and is **entirely optional** (defaults
shown above). `max_items` caps how many TASKS.md rows one `/sdlc --queue`
invocation consumes; `batch_size` is read only by `scripts/loop-runner.sh` and
sets how many completed items a single headless process handles before context
is reset at a clean boundary; `max_hops` bounds the auto-continue chain.
`auto_continue` is **off by default** and Claude/Codex only. When true, the Stop
hook executes a single non-`confirm` `.next-action` entry instead of just
printing it, so the loop self-advances. It never chains a `confirm: true` action
(i.e. never a commit or any other git write). See `docs/LOOP-HYGIENE.md`.

### Which skill reads which key

| Skill | Reads |
|---|---|
| `/test-check` | `test.*`, `logs.*` |
| `/sdlc` | `gotchas_file`, `eval.*`, `main_branch`, delegates to `/test-check` |
| `/gotcha` | `gotchas_file` |
| `/brainstorm` | `modules`, `models.cap` |
| `/sdlc`, `/brainstorm-team`, `/dead-code-review` | `models.cap` (sub-agent tier ceiling) |
| `/sdlc` | `models.sanity` + `agents.sanity_focuses` (Stage 1.5 pre-flight; never gated, so it runs every time) |
| `/sdlc` | `models.code_review`, `models.code_review_second_pass`, `agents.code_review_*` (axis 2; never capped) |
| `/sdlc` | `pipeline.review_fix.*`: stage *behavior* only (`enabled`, `mode`). Opt-in, permanently off by default. (`blocking` was removed 2026-09: `/sdlc` does no git writes, so a HIGH finding is reported first in Stage 7, never gated) |
| `/sdlc` | `agents.decompose_min_tasks` / `agents.decompose_min_files` (Stage 2 decompose gate) |
| `/sdlc` Stage 0 | `pipeline.scope.max_steps_per_run` (scope gate; `--no-scope-gate` bypasses per-run) |
| `/sdlc --queue`, `scripts/loop-runner.sh`, `scripts/hooks/next-action.sh` | `pipeline.loop.*` (`max_items`, `batch_size`, `max_hops`, `auto_continue`) |
| `/sdlc` Stage 6 | `stack.up` / `stack.rebuild` / `stack.url`: printed as the manual-verification line at hand-off, never auto-run |
| `/sdlc` Stage 6 | `coauthor_trailer`: whether the *suggested* commit message carries the trailer (`/sdlc` prints it; it never commits) |
| `/task` | `coauthor_trailer` (only when you ask it to commit); otherwise reads TASKS.md directly |
| `/sdlc-status` | (none; reads TASKS.md and `.claude/pipeline/` directly) |
| `scripts/py.sh` (every shipped Python invocation) | `python` |
| `scripts/hooks/enforce-model-cap.sh` (Claude `PreToolUse(Agent)`) | `pipeline.enforce_cap`, `models.cap` |
| `scripts/hooks/stop-gate.sh` (Claude/Codex `Stop`) | `pipeline.stop_gate`, `pipeline.stop_gate_timeout`, `test.unit`, `pipeline.loop.max_hops` |
| `scripts/hooks/run-cost-report.sh` (Claude/Codex `Stop`) | `pipeline.context.cost_report` |
| `/sdlc` Stage 5.9 | `pipeline.cleanup.*`, `agents.cleanup_lenses`, `agents.cleanup_max_lenses` |
| `/sdlc` Stage 5.7 | `agents.code_review_max_lenses` |
| `/sdlc` changed-files gate | `discipline.*` (`staleness_hours`, `*_globs`, `deploy_delta_globs`) |
| `/repo-health` | `migrations.dir`, `migrations.applied_check`, `discipline.memory_index` |
| `/sdlc` all stages | `pipeline.output.verbosity` |
| `/test-check --loop`, `e2e-test-runner` | `test.e2e_max_fix_loops`, `test.e2e_patterns_file`, `test.e2e_rerun_failed_only` |
| `scripts/eval-runner.py` | `eval.thresholds.min_pass_rate` |
| `/repo-onboarding` | writes all of the above |
