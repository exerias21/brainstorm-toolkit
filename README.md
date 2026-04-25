# brainstorm-toolkit

Cross-tool plugin for **Claude Code + GitHub Copilot**: focused, low-token skills for brainstorming, SDLC, eval-driven development, and repo onboarding. Single AGENTS.md and TASKS.md contract so both agents work from the same source of truth.

## Why this exists

Most AI-agent task systems bolt on heavyweight task databases, multi-agent orchestrators, and inline templates that balloon every command to hundreds of lines. brainstorm-toolkit goes the other direction:

- **One skill = one SKILL.md file**, deliberately short (37–250 lines each).
- **Markdown-native contracts** — `AGENTS.md`, `TASKS.md`, `GOTCHAS.md`, `.claude/project.json` — so Claude Code, GitHub Copilot, Cursor, and friends all read the same files.
- **No central registry**, no dual persistence, no ralph-loop autonomous runners by default. `/sdlc` is the heaviest thing in here and it's still one file.

## Install

### Option A — Claude Code plugin

If you use the Claude Code plugin system, add this repo as a marketplace source or install directly:

```bash
# In Claude Code:
/plugin marketplace add <this-repo-url>
/plugin install brainstorm-toolkit
```

### Option B — `setup.sh` (Claude, Copilot, or both)

For Copilot users, or if you prefer file-based installs:

```bash
# Clone this repo once, anywhere
git clone <this-repo-url> ~/brainstorm-toolkit

# Inside any target repo:
bash ~/brainstorm-toolkit/setup.sh --target . --tools both
```

`setup.sh` copies:

- `skills/*` → `<target>/.claude/skills/<name>/` (Claude) and `<target>/.github/skills/<name>/` (Copilot, for skills marked for both tools). When a Copilot-optimized override exists in `copilot/skills/<name>/`, that version is installed instead of the canonical one. The full skill directory is copied so bundled scripts, assets, and references stay available.
- Some Copilot-distributed skills are intentionally **manual-only** and set `disable-model-invocation: true`, which keeps them available as slash commands without making them auto-load on semantic matching.
- Legacy `.github/prompts/*.prompt.md` files from older installs are removed during Copilot installs so the workspace stops advertising prompt-file shims.
- `agents/*` → `<target>/.claude/agents/` (Claude-only helper agents; VS Code can also discover Claude-format agents from `.claude/agents/` when needed).
- `scripts/*` → `<target>/scripts/`.
- `templates/AGENTS.md.template` → `<target>/AGENTS.md` if missing. Symlinks `CLAUDE.md → AGENTS.md` on POSIX, else copies.
- `templates/TASKS.md.template` → `<target>/TASKS.md` if missing.
- `templates/project.json.example` → `<target>/.claude/project.json.example` (left for you to rename and edit).

Re-running `setup.sh` is safe — it skips existing files unless you pass `--force`. Install only for one tool with `--tools claude` or `--tools copilot`.

### Windows note

`setup.sh` is bash; run it under **WSL, Linux, or macOS**. Windows-native git handles symlinks inconsistently, so the `CLAUDE.md → AGENTS.md` link falls back to a copy outside POSIX environments.

## The cross-tool contract

Every consumer repo gets four shared files:

| File | Purpose | Read by |
|---|---|---|
| `AGENTS.md` | Architecture + agent conventions | Claude Code (via `CLAUDE.md` copy/symlink), Copilot, Cursor, Codex |
| `TASKS.md` | Markdown checkbox task queue | All agents, humans, GitHub UI |
| `GOTCHAS.md` | Project-specific pitfalls | `/gotcha`, `/sdlc` sanity check |
| `.claude/project.json` | Runner config (tests, logs, eval) | `/test-check`, `/eval-harness`, `/sdlc` |

Every `project.json` key is optional — skills skip steps gracefully when config is missing. A repo with no `project.json` still gets useful behavior from `/brainstorm`, `/task`, `/gotcha`, etc.

## Skills

| Skill | Applies to | Use for |
|---|---|---|
| `/brainstorm` | Both † | Conversational feature ideation with lens-divergent wildcards (Plan mode on Claude, linear on Copilot) |
| `/brainstorm-team` | Both † | 6-agent team for competitive + product research incl. a lateral-thinking agent (sequential on Copilot) |
| `/task` | Both | Create one bounded task and execute it with TDD |
| `/status` | Both | Quick readout of TASKS.md counts + active task |
| `/sdlc` | Both † | Plan → implement → eval → test → flowsim → PR (sequential on Copilot) |
| `/repo-onboarding` | Both | Generate AGENTS.md + TASKS.md + project.json + GOTCHAS.md |
| `/test-check` | Both | Run configured tests + log audit after changes (one-shot, no fix loop) |
| `/e2e-loop` | Both † | Run e2e tests in a fix loop with flaky-test guard (dispatches `e2e-test-runner` agent on Claude, inline on Copilot) |
| `/gotcha` | Both | View or append project pitfalls |
| `/eval-harness` | Both | Run pytest + fixture evals with optional fix loop |
| `/flowsim` | Both | Trace claimed plan flows through source code and flag mismatches |
| `/dead-code-review` | Both † | Dead-code scan with test verification (sequential on Copilot) |
| `/data-source-pattern` | Both | Pattern guide for scrapers, seed scripts, API ingestion |
| `/logging-conventions` | Both | Enforce structured logging discipline |
| `/post-deploy-verify` | Both | Stub — post-deploy BRD/PBI-vs-deployed-system verification matrix (depends on Phase 2 BRD/PBI artifacts; see `BRAINSTORM-PIPELINE.md`) |

† Has a Copilot-optimized overlay at `copilot/skills/<name>/`. The overlay runs the same stages sequentially (no parallel sub-agents or Plan mode) because Copilot's VS Code agent mode doesn't yet support those primitives. When it does, overlays will be upgraded. Cross-tool skills without a † rely only on file I/O + test runners and work identically on both tools.

## Flows

Tool-specific walkthroughs are in `docs/`:

- **[docs/FLOW-CLAUDE-CODE.md](docs/FLOW-CLAUDE-CODE.md)** — install, daily loop, sub-agent use, `/sdlc` stages, `project.json` config, TASKS.md vs native Tasks.
- **[docs/FLOW-COPILOT.md](docs/FLOW-COPILOT.md)** — install via `gh skill install` or `setup.sh`, `chat.agentSkillsLocations`, `/skills` menu, overlay semantics, cloud agent specifics, `disable-model-invocation`.

## Typical workflow

```
   /repo-onboarding                (once per repo)
          │
          ▼
   AGENTS.md + TASKS.md + project.json + GOTCHAS.md
          │
          ├──► /brainstorm  ──► plan file + TASKS.md rows
          │                             │
          │                             ▼
          ├──► /task  ──────► TDD on a single small item
          │
          └──► /sdlc <plan>  ──► autonomous implement + eval + test + flowsim + PR

   /status   — any time: "what's active, what's left?"
   /flowsim  — verify a plan's claimed flows match the code (auto-run by /sdlc)
   /gotcha   — when you discover a pitfall
```

## Config contract

`.claude/project.json` — all keys optional:

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
|---|---|
| `/test-check` | `test.*`, `logs.*` |
| `/eval-harness` | `eval.*` |
| `/sdlc` | `gotchas_file`, `eval.*`, `main_branch`, delegates to `/test-check` |
| `/gotcha` | `gotchas_file` |
| `/brainstorm` | `modules` |
| `/task`, `/status` | (none — read TASKS.md directly) |
| `/repo-onboarding` | writes all of the above |

## Supporting scripts

- **`scripts/eval-runner.py`** — runs pytest + fixture-based pipeline evals. Auto-discovers features from `evals/*/`. See `skills/eval-harness/SKILL.md`.
- **`scripts/check_docker_logs.py`** — audits logs for errors/tracebacks. Accepts `--log-command` and `--services`. Works with Docker, kubectl, journalctl, or any log source.
- **`scripts/validate_skills.py`** — validates skill metadata, name-to-directory alignment, and Copilot-targeted skills against Claude-only capability leakage.

## Maintaining this repo

This repo is the canonical source. Consumer repos are populated by `setup.sh` — to propagate updates, re-run `setup.sh --force` in each consumer repo. There is intentionally no auto-sync.

See `AGENTS.md` for skill authoring rules (frontmatter, ceilings, contracts).
