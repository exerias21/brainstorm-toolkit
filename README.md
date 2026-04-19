# Claude Workflow Toolkit

Portable Claude Code skills + agents + supporting scripts.

## What's in here

```
skills/
  brainstorm/            # Conversational feature ideation (Plan mode)
  brainstorm-team/       # 5-agent team for product strategy docs
  gotcha/                # Maintains GOTCHAS.md — project-specific pitfalls
  dead-code-review/      # Parallel dead-code scan + test verification
  logging-conventions/   # Structured logging discipline
  data-source-pattern/   # Pattern guide for ingesting external data
  sdlc/                  # Plan → implement → eval → test → PR pipeline
  test-check/            # Post-change validation (tests + log audit)
  eval-harness/          # pytest + fixture pipeline evals with fix loop
  repo-onboarding/       # Inspect repo, generate .claude/project.json
agents/
  sdlc-pipeline.md       # Agent definition for the full SDLC flow
  ux-plan-validator.md   # Agent definition for plan-requirement validation
scripts/
  eval-runner.py         # Auto-discovers features under evals/*/
  check_docker_logs.py   # Configurable log auditor (docker/kubectl/file)
examples/
  project.json.example   # Config contract template
  GOTCHAS.md.example     # Empty gotchas file template
```

## Install in a new repo

Copy-paste. No plugin system, no package manager.

```bash
cd /path/to/your-repo

# Skills and agents go under .claude/
mkdir -p .claude
cp -r /mnt/c/programming/workflow-toolkit/skills .claude/
cp -r /mnt/c/programming/workflow-toolkit/agents .claude/

# Scripts can live wherever the repo conventionally keeps scripts
cp -r /mnt/c/programming/workflow-toolkit/scripts ./scripts/

# Generate the config. Two options:
# A) Use the onboarding skill:
#    In Claude Code: /repo-onboarding
# B) Or copy the template and edit by hand:
cp /mnt/c/programming/workflow-toolkit/examples/project.json.example .claude/project.json
```

## The config contract

Each consuming project has a `.claude/project.json`. All keys are **optional** —
skills skip steps gracefully when a key is missing. This means a repo with no
`project.json` still gets useful behavior from `/brainstorm` and `/gotcha`.

```json
{
  "test": {
    "unit": "pytest tests/ -v --tb=short",
    "frontend": "cd web && pnpm test --run",
    "e2e": "npx playwright test"
  },
  "logs": {
    "command": "docker compose logs {service} --tail={tail}",
    "services": ["api", "web"]
  },
  "eval": {
    "runner": "python3 scripts/eval-runner.py",
    "features_dir": "evals/"
  },
  "gotchas_file": "GOTCHAS.md",
  "main_branch": "main",
  "modules": ["api", "web", "worker"]
}
```

### Which skill reads which key

| Skill | Reads |
|-------|-------|
| `/test-check` | `test.*`, `logs.*` |
| `/eval-harness` | `eval.*` |
| `/sdlc` | `gotchas_file`, `eval.*`, `main_branch`, delegates to `/test-check` |
| `/gotcha` | `gotchas_file` |
| `/brainstorm` | `modules` |
| `/repo-onboarding` | writes it |

## Typical workflow

1. `/repo-onboarding` — one-time setup per repo.
2. `/brainstorm [topic]` — ideate + produce a plan file.
3. `/sdlc plans/<your-plan>.md` — implement → eval → test → PR.
4. `/test-check` — ad-hoc post-change validation.
5. `/gotcha [Category] description` — record pitfalls as you discover them.

## Supporting scripts

`scripts/eval-runner.py` — runs pytest + fixture-based pipeline evals.
Auto-discovers features from `evals/*/` directories. Optional `meta.json`
in each feature dir maps to a script path + test file. See `skills/eval-harness/SKILL.md`.

`scripts/check_docker_logs.py` — audits logs for errors/tracebacks. Accepts
`--log-command` (default: `docker compose logs {service} --tail={tail}`) and
`--services api web ...`. Works with kubectl, journalctl, or any log source —
just pass the appropriate command.

## Maintaining the toolkit

This directory is the canonical source. To propagate updates to consuming repos,
re-copy the updated files. There's no auto-sync — that's by design for simplicity.
