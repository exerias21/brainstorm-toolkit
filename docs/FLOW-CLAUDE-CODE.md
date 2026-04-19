# Flow: brainstorm-toolkit in Claude Code

End-to-end user journey for Claude Code users (CLI, desktop, or web). The toolkit assumes you start in a repo that already has code and tests; it is not a project scaffolder.

## Install

**Option A — Claude Code plugin marketplace** (preferred once the repo is public):
```
/plugin marketplace add <this-repo-url>
/plugin install brainstorm-toolkit
```

**Option B — `setup.sh` for file-based install** (works today from a local clone):
```bash
git clone <this-repo-url> ~/brainstorm-toolkit
cd /path/to/your-repo
bash ~/brainstorm-toolkit/setup.sh --target . --tools claude
```

After install you have:
- `.claude/skills/<name>/SKILL.md` for every skill
- `.claude/agents/*.md` (sub-agent definitions for `/sdlc` and `/flowsim`)
- `scripts/eval-runner.py`, `scripts/check_docker_logs.py` at repo root
- `AGENTS.md` + `CLAUDE.md` (symlinked on POSIX, copied elsewhere)
- `TASKS.md` at repo root
- `.claude/project.json.example` (rename + edit to `project.json`)

## Daily inner loop

```
   /repo-onboarding        ← once, to generate AGENTS.md + project.json + GOTCHAS.md
        │
        ▼
   ┌─ Small bounded ask ──────────────────┐
   │  /task "add formatPhone util"        │
   │  → TDD loop, 1 row in TASKS.md       │
   └──────────────────────────────────────┘
        or
   ┌─ Feature-sized ask ──────────────────┐
   │  /brainstorm              ← Plan mode, conversational
   │  → plans/brainstorm-<slug>.md        │
   │  → /sdlc plans/brainstorm-<slug>.md  ← autonomous pipeline
   └──────────────────────────────────────┘

   /status    — any time
   /gotcha    — when you discover a project-specific pitfall
```

## What's Claude-only and why

Some skills use primitives Copilot doesn't have. You get the full version in Claude Code:

- **`/brainstorm`** — enters Plan mode (`EnterPlanMode`) to separate planning from implementation. The Copilot overlay is linear (no plan mode).
- **`/brainstorm-team`** — spawns 5 sub-agents in parallel via the `Agent` tool. The Copilot overlay runs them sequentially.
- **`/sdlc`** — spawns Haiku agents for plan sanity-check, an Opus agent for implementation, parallel Sonnet/Haiku validators, and `/flowsim` for flow verification. The Copilot overlay is sequential — useful but slower and lower-coverage.
- **`/dead-code-review`** — launches 6 parallel Opus agents. The Copilot overlay walks the 6 phases sequentially.

Claude-only features you'll use directly:
- **Plan mode** — `/brainstorm` enters, then `/sdlc` can re-enter to request plan approval before implementing.
- **Sub-agent spawning** — `/sdlc` Stage 1.5 (sanity), Stage 2 (implement), Stage 5.5 (validation), Stage 5.6 (`/flowsim` narrative trace).
- **TaskCreate / TaskUpdate** — `/task` mirrors TASKS.md rows into native Claude Tasks for the live progress indicator in the UI. Copilot has no equivalent; the markdown is authoritative.

## `/sdlc` walkthrough

```
/sdlc plans/brainstorm-add-orders.md
```

Stages:
1. Parse plan (accepts `plans/brainstorm-*.md`, `plans/tasks/task-N-*.md`, or TASKS.md rows).
2. Plan sanity-check (3 Haiku agents in parallel check file paths, missing steps, known gotchas).
3. Implement via an Opus agent, following the plan steps exactly.
4. Generate evals under `tests/eval/` and/or fixtures under `<eval.features_dir>/`.
5. Eval + fix loop (up to `--max-fix-loops`, default 3).
6. Validate via `/test-check` (log audit + unit + e2e).
7. Plan requirements validation (4 parallel agents: API, UI, data, cross-module).
8. `/flowsim` (unless `--skip-flowsim`) — narrative trace through claimed flows.
9. Create PR branch, commit, push, `gh pr create`.

Useful flags: `--dry-run`, `--skip-eval`, `--skip-flowsim`, `--max-fix-loops N`, `--background`.

## `project.json` config

Create `.claude/project.json` from `.claude/project.json.example`. Every key is optional — skills skip cleanly if missing:

- `test.unit`, `test.frontend`, `test.e2e` → used by `/test-check`, `/sdlc`
- `logs.command`, `logs.services` → used by `/test-check` (log audit step)
- `eval.runner`, `eval.features_dir` → used by `/eval-harness`, `/sdlc`
- `gotchas_file` → used by `/gotcha`, `/sdlc` sanity check
- `main_branch` → used by `/sdlc` for PR base
- `modules` → used by `/brainstorm` cross-module check

## TASKS.md vs native Tasks

- **TASKS.md** is the source of truth. Plain markdown checkboxes. Readable by humans, Copilot, any future tool.
- **Native Tasks** (TaskCreate / TaskUpdate) are a Claude-only live mirror. `/task` optionally creates them for the in-session UI indicator. They don't persist across sessions.
- When they disagree, TASKS.md wins. Don't build sync logic; just re-read TASKS.md at the start of each session.

## Tips

- Run `/repo-onboarding` in any repo that doesn't already have `AGENTS.md`. It only takes a minute and every other skill gets more useful after.
- Use `/task --defer` when you want a task file written but don't want to execute immediately (e.g., at end of day to queue tomorrow's work).
- `/sdlc --dry-run` is cheap and surfaces plan problems before you commit Opus tokens.
- For interactive brainstorming on a meaty topic, use `/brainstorm`. For multi-agent competitive/product research, use `/brainstorm-team`.

## See also

- [FLOW-COPILOT.md](FLOW-COPILOT.md) — same toolkit, VS Code Copilot flow
- [../AGENTS.md](../AGENTS.md) — skill authoring rules for contributors
- [../README.md](../README.md) — install + skills table
