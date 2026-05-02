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
- `templates/CHEATSHEET.md.template` → `<target>/CHEATSHEET.md` if missing. This is the printable companion to `/cheatsheet`; once present, setup leaves user edits alone.
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
| `/cheatsheet` | Both | Print every installed skill + the typical chains. The always-current view; `CHEATSHEET.md` is the printable companion. |
| `/brainstorm` | Both † | Conversational feature ideation with lens-divergent wildcards (Plan mode on Claude, linear on Copilot) |
| `/brainstorm-team` | Both † | 6-agent team for competitive + product research incl. a lateral-thinking agent (sequential on Copilot) |
| `/task` | Both | Create one bounded task and execute it with TDD |
| `/status` | Both | Quick readout of TASKS.md counts + active task |
| `/sdlc` | Both † | Plan → implement → eval → test → flowsim → PR (sequential on Copilot) |
| `/repo-onboarding` | Both | Generate AGENTS.md + TASKS.md + project.json + GOTCHAS.md |
| `/repo-health` | Both | Read-only hygiene sweep (dead code + tests + deps + secrets + gotchas-currency); prints a scored report and the highest-impact next command. |
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

## Model & cost reference

What each skill dispatches under the hood, and a rough order-of-magnitude
cost. Token counts are **per typical run**, not worst-case — a `/sdlc` run
on a tiny plan is closer to the low end, on a multi-module refactor the
high end. Costs use 2026-04 list pricing: Opus $15 / $75, Sonnet $3 / $15,
Haiku $1 / $5 per M tokens (input / output).

| Skill | Orchestrator | Sub-agents (per run) | Tokens/run (rough) | Cost/run (rough) |
|---|---|---|---|---|
| `/cheatsheet` | host model | none — file I/O only | <1k | ~$0.00 |
| `/status` | host model | none — reads `TASKS.md` | <1k | ~$0.00 |
| `/gotcha` | host model | none — read/append `GOTCHAS.md` | <1k | ~$0.00 |
| `/data-source-pattern` | host model | none — reference doc | <1k | ~$0.00 |
| `/logging-conventions` | host model | none — reference doc | <1k | ~$0.00 |
| `/test-check` | host model | none — runs tests + log audit | 1k–3k | ~$0.01 |
| `/task` | host model | none — inline TDD | 5k–15k | $0.02–$0.10 |
| `/repo-health` | host model | 2 × Haiku (dead-code + gotchas-currency); 3 procedural checks | 5k–20k | $0.02–$0.10 |
| `/eval-harness` | host model | 0–1 × Sonnet (optional fix loop) | 5k–30k | $0.02–$0.30 |
| `/flowsim` | host model | none — plan-vs-code grep | 10k–40k | $0.05–$0.40 |
| `/e2e-loop` | host model | 1 × Sonnet per fix iteration | 10k–30k / iter | $0.05–$0.30 / iter |
| `/repo-onboarding` | host model (Opus recommended) | 0–1 × Sonnet (pattern detection) | 20k–60k | $0.30–$1.00 |
| `/brainstorm` (`light`) | host (Opus) | 3 × Haiku lens agents | 20k–50k | $0.10–$0.40 |
| `/brainstorm` (`deep`) | host (Opus) | 3 × Haiku + 1 × Sonnet stress-test | 30k–70k | $0.20–$0.80 |
| `/brainstorm` (`ultra`) | host (Opus) | 3 × Haiku + 1 × Sonnet + 2 × Opus | 60k–120k | $1.00–$3.00 |
| `/brainstorm-team` | host (Opus) | 6 × Sonnet teammates (4 parallel, 2 sequential) | 60k–150k | $0.60–$2.00 |
| `/dead-code-review` | host (Opus) | 3 × Haiku + 2 × Sonnet + 1 × Opus (parallel) | 80k–200k | $0.80–$2.50 |
| `/post-deploy-verify` | host model | 2 × Haiku + 1 × Sonnet **per PBI batch** | scales with batch | $0.10–$1.00 / batch |
| `/sdlc` | host (Opus) | 3 × Haiku (sanity) + 1 × Opus (impl) + 2–4 × Haiku/Sonnet (validate) + optional Opus/Sonnet (eval-fix) + Sonnet (e2e) | 100k–300k | $3.00–$10.00 |

**Notes / caveats**:

- The "host model" / "orchestrator" is whichever model is running the
  Claude Code or Copilot session — the toolkit doesn't pin it. Costs
  above assume Opus for Plan-mode-bearing skills (`/brainstorm`, `/sdlc`,
  `/dead-code-review`) and whatever the user has selected otherwise.
- **Orchestrator context dominates real cost.** An Opus orchestrator
  carrying a 100k-token codebase context across 5 sub-agent dispatches
  pays the input cost 5× — agent dispatch fees themselves are usually
  10–20% of the bill. Keeping orchestrator context tight is the highest-
  leverage cost lever.
- Sonnet is the right default for parallel sub-agents that do bounded
  code-search / pattern-match / judgement work. Opus is reserved for
  cross-module reasoning where one wrong call costs more than the whole
  fan-out. Haiku is right when the task is "find the regex match" not
  "judge what to do about it."
- These numbers are calibration, not budgeting. Real runs vary 3–5× with
  repo size, plan complexity, and how much context the orchestrator has
  already accumulated when the skill fires.

## Flows

Tool-specific walkthroughs are in `docs/`:

- **[docs/FLOW-CLAUDE-CODE.md](docs/FLOW-CLAUDE-CODE.md)** — install, daily loop, sub-agent use, `/sdlc` stages, `project.json` config, TASKS.md vs native Tasks.
- **[docs/FLOW-COPILOT.md](docs/FLOW-COPILOT.md)** — install via `gh skill install` or `setup.sh`, `chat.agentSkillsLocations`, `/skills` menu, overlay semantics, cloud agent specifics, `disable-model-invocation`.

## Typical workflow

```mermaid
flowchart LR
    A[/repo-onboarding/]:::setup --> B[AGENTS.md + TASKS.md<br/>project.json + GOTCHAS.md]
    B --> C[/brainstorm/]
    B --> D[/task/]
    B --> E[/pbi/<br/>Phase 1D]
    C --> F[plans/brainstorm-*.md]
    E --> G[plans/pbi-NNN-*.md]
    D --> H[inline TDD]
    F --> I[/sdlc {plan}/]:::core
    G --> I
    H --> J[PR]
    I --> J
    J --> K[merge]
    K --> L[/post-deploy-verify/<br/>pipeline profile]:::pipe

    subgraph "Anytime, in parallel"
      M[/cheatsheet/<br/>discover]
      N[/repo-health/<br/>scored sweep]
      O[/flowsim {plan}/<br/>plan-vs-code drift]
      P[/dead-code-review/<br/>deeper hygiene]
      Q[/gotcha/<br/>capture pitfall]
    end

    classDef setup fill:#e8e8ff,stroke:#5555aa
    classDef core fill:#e0ffe0,stroke:#338833
    classDef pipe fill:#fff0e0,stroke:#cc7733
```

Or in plain text:

```
   /repo-onboarding                (once per repo)
          │
          ▼
   AGENTS.md + TASKS.md + project.json + GOTCHAS.md + CHEATSHEET.md
          │
          ├──► /brainstorm   ──► plan file
          │                          │
          │                          ▼
          ├──► /pbi          ──► PBI + plan ──┐
          │                                    │
          ├──► /task         ──► TDD inline ──┼──► PR
          │                                    │
          └──► /sdlc <plan>  ──► autonomous ──┘
                                  implement → eval → test → flowsim → PR

   Anytime:
     /cheatsheet     — what skills are installed?
     /repo-health    — scored hygiene sweep
     /status         — what's active, what's left?
     /flowsim        — verify a plan's claimed flows match the code
     /gotcha         — capture a pitfall
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
